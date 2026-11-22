#!/usr/bin/env python3
"""Converts an mpv FSRCNNX user shader (as shipped with chiaki-ng) into Metal compute kernels.

Usage: python3 Tools/gen-fsrcnnx.py <shader.glsl> <Name> > Sources/PS5Stream/FSRCNNX<Name>.swift
  e.g.  python3 Tools/gen-fsrcnnx.py vendor/chiaki-ng/gui/res/shaders/FSRCNNX_x2_16-0-4-1.glsl HQ

Passes that make up one network layer (same DESC prefix) are fused into a single kernel, so each
neighbourhood tap is read once per layer instead of once per output texture. Each kernel reads its
inputs with integer texel offsets (clamped at the edges, like mpv) and writes rgba16Float outputs.
The final "aggregation" pass becomes a 2x kernel that scatters the 4 sub-pixel channels.
"""
import os
import re
import sys

# Half precision runs about twice as fast on Apple GPUs; FSRCNNX_FLOAT=1 generates float32 kernels.
T = "float" if os.environ.get("FSRCNNX_FLOAT") else "half"

path, NAME = sys.argv[1], sys.argv[2]
src = open(path).read()
P = NAME.lower() + "_"

header = "\n".join(l for l in src.splitlines() if l.startswith("//") and not l.startswith("//!"))
passes = []
for block in src.split("//!HOOK")[1:]:
    meta = dict(desc=None, binds=[], save=None, w=None)
    lines = block.splitlines()
    body = []
    for l in lines[1:]:
        if l.startswith("//!DESC"): meta["desc"] = l[8:].strip()
        elif l.startswith("//!BIND"): meta["binds"].append(l[8:].strip())
        elif l.startswith("//!SAVE"): meta["save"] = l[8:].strip()
        elif l.startswith("//!WIDTH"): meta["w"] = l
        elif l.startswith("//!"): pass
        else: body.append(l)
    code = "\n".join(body)
    code = code[code.index("{") + 1: code.rindex("}")]
    meta["body"] = code.strip()
    passes.append(meta)

agg = [p for p in passes if p["w"]]
assert len(agg) == 1 and passes[-1] is agg[0], "expected one final 2x aggregation pass"
layers = []  # (name, [passes])
for p in passes[:-1]:
    key = re.sub(r"\s*\d+(_\d+)?$", "", p["desc"]) + (re.match(r".*?(\d+)_\d+$", p["desc"]).group(1) if re.match(r".*?\d+_\d+$", p["desc"]) else "")
    if layers and layers[-1][0] == key: layers[-1][1].append(p)
    else: layers.append((key, [p]))

def fmt_mat(m):
    nums = [x.strip() for x in m.group(1).split(",")]
    assert len(nums) == 16
    cols = ["float4(" + ",".join(nums[i*4:(i+1)*4]) + ")" for i in range(4)]
    return f"{T}4x4(" + ", ".join(cols).replace("float4(", f"{T}4(") + ")"

kernels = []
for li, (key, ps) in enumerate(layers):
    inputs = []
    for p in ps:
        for b in p["binds"]:
            if b not in inputs: inputs.append(b)
    outputs = [p["save"] for p in ps]
    taps = {}
    def tap(name, dx, dy):
        k = (name, dx, dy)
        if k not in taps: taps[k] = f"{name.lower()}_{dx}_{dy}".replace("-", "m")
        return taps[k]
    blocks = []
    for oi, p in enumerate(ps):
        c = p["body"]
        c = re.sub(r"mat4(?:x4)?\(([^()]*)\)", fmt_mat, c)
        def repl_off(m):
            name, arg = m.group(1), m.group(2).strip()
            if arg == "0": dx, dy = 0, 0
            else:
                a = re.match(r"vec2\((-?\d+),\s*(-?\d+)\)", arg)
                dx, dy = int(a.group(1)), int(a.group(2))
            return tap(name, dx, dy)
        c = re.sub(r"([A-Z0-9]+)_texOff\(((?:vec2\([^)]*\))|0)\)", repl_off, c)
        c = re.sub(r"float\((luma_[0-9m_]+)\)", r"\1.x", c)
        c = c.replace("vec4", f"{T}4")
        c = re.sub(r"return\s+(?:float|half)4\(res\);|return\s+res;", f"o{oi}.write(res, gid);", c)
        blocks.append("    {\n" + "\n".join("        " + l for l in c.splitlines()) + "\n    }")
    params = [f"texture2d<{T}, access::read> {n.lower()} [[texture({i})]]" for i, n in enumerate(inputs)]
    params += [f"texture2d<{T}, access::write> o{i} [[texture({len(inputs) + i})]]" for i in range(len(outputs))]
    loads = [f"    {T}4 {v} = {n.lower()}.read(uint2(clamp(p + int2({dx}, {dy}), int2(0), m)));"
             for (n, dx, dy), v in taps.items()]
    name = f"{P}layer{li}"
    kernels.append((name, inputs, outputs, key,
        f"kernel void {name}(\n    " + ",\n    ".join(params + ["uint2 gid [[thread_position_in_grid]]"]) + ")\n{\n"
        f"    if (gid.x >= o0.get_width() || gid.y >= o0.get_height()) return;\n"
        f"    int2 p = int2(gid), m = int2(o0.get_width() - 1, o0.get_height() - 1);\n"
        + "\n".join(loads) + "\n" + "\n".join(blocks) + "\n}\n"))

# Every layer's weights as a plain convolution, for the buffer + matrix-unit path in
# NeuralUpscaler.swift: weights[tap][in][out] with tap = (dy+r)*k + (dx+r) for a k x k kernel (r = k/2),
# bias[out], PReLU slope[out] (empty when the layer has no activation), and whether the layer adds the
# feature map (the network's skip connection) before its activation.
convs = []
term_re = re.compile(r"(?:mat4(?:x4)?\(([^()]*)\)|vec4\(([^()]*)\)) \* (?:float\()?([A-Z0-9]+)_texOff\((?:vec2\((-?\d+),\s*(-?\d+)\)|0)\)")
for key, ps in layers:
    terms, ins = [], []
    for k, p in enumerate(ps):
        for m in term_re.finditer(p["body"]):
            name = m.group(3)
            dx, dy = int(m.group(4) or 0), int(m.group(5) or 0)
            nums = [float(x) for x in (m.group(1) or m.group(2)).split(",")]
            terms.append((k, name, dx, dy, nums))
            if name not in ins: ins.append(name)
    r = max(max(abs(t[2]), abs(t[3])) for t in terms)
    ks = 2 * r + 1
    cin = 1 if ins == ["LUMA"] else 4 * len(ins)
    cout = 4 * len(ps)
    W = [0.0] * (ks * ks * cin * cout); bias = []; alpha = []; residual = False
    for k, p in enumerate(ps):
        body = p["body"]
        bias += [float(x) for x in re.search(r"res = vec4\(([^)]*)\)", body).group(1).split(",")]
        a = re.search(r"max\(res, vec4\(0\.0\)\) \+ vec4\(([^)]*)\)", body)
        if a: alpha += [float(x) for x in a.group(1).split(",")]
        res = re.search(r"res \+= ([A-Z0-9]+)_texOff\(0\);", body)
        if res:
            assert res.group(1) == f"FEATURE{k + 1}", "skip connection must add the matching feature channels"
            residual = True
    for k, name, dx, dy, nums in terms:
        t = (dy + r) * ks + (dx + r)
        if cin == 1:
            for o in range(4): W[(t * cin) * cout + 4 * k + o] = nums[o]
        else:
            j = ins.index(name)
            for c in range(4):
                for o in range(4):
                    W[(t * cin + 4 * j + c) * cout + 4 * k + o] = nums[c * 4 + o]
    convs.append(dict(kernel=ks, inputs=ins, outputs=[p["save"] for p in ps], cin=cin, cout=cout,
                      W=W, bias=bias, alpha=alpha, residual=residual, key=key))

last = agg[0]["binds"][0]
agg_kernel = f"""kernel void {P}aggregate(
    texture2d<{T}, access::read> sub [[texture(0)]],
    texture2d<{T}, access::write> out [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    {T}4 v = sub.read(gid / 2);
    out.write({T}4(v[(gid.x & 1) * 2 + (gid.y & 1)], 0, 0, 1), gid);
}}
"""

print(f"// Generated by Tools/gen-fsrcnnx.py from chiaki-ng's {os.path.basename(path)}. Do not edit.")
print("// FSRCNNX network weights:")
print("\n".join(header.splitlines()))
print()
print("/// One entry per fused layer: kernel name, input texture names, output texture names.")
def floats(v): return "[" + ", ".join(repr(float(x)) for x in v) + "]"
print(f"let fsrcnnx{NAME} = FSRCNNXNetwork(aggregate: \"{P}aggregate\", convs: [")
for c in convs:
    print(f"    FSRCNNXConv(kernel: {c['kernel']}, inChannels: {c['cin']}, outChannels: {c['cout']}, residual: {'true' if c['residual'] else 'false'},  // {c['key']}")
    print(f"                weights: {floats(c['W'])} as [Float],")
    print(f"                bias: {floats(c['bias'])} as [Float], alpha: {floats(c['alpha'])} as [Float]),")
print("], layers: [")
for name, ins, outs, key, _ in kernels:
    print(f'    ("{name}", {ins!r}, {outs!r}),  // {key}'.replace("'", '"'))
print("], source: fsrcnnx" + NAME + "Source)")
print()
print(f'private let fsrcnnx{NAME}Source = """')
print("#include <metal_stdlib>\nusing namespace metal;\n")
for k in kernels: print(k[4])
print(agg_kernel + '"""')
