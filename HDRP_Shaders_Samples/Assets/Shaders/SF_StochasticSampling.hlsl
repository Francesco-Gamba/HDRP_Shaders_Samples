// StochasticSampling. Shader Graph Custom Function that breaks visible texture
// tiling on organic surfaces. Hex-grid decomposition picks three cells per pixel,
// each driving a randomized UV transform (rotation, scale, offset) via a Hoskins
// hash. Three samples blended by hex weights, with per-sample normal rotation
// (XY rotated, Z preserved) for correct lighting across blends.

#define TAU 6.28318530718

struct HexGrid{
  float3 Weight;
  float2 IdX;
  float2 IdY;
  float2 IdZ;  
};

struct RandomUV{
    float2 TransformedUV;
    float Rotation;
};

float3 hash23(float2 seed){
    float3 p3 = frac(float3(seed.xyx) * float3(443.897,441.423,437.195));
    p3 += dot(p3, p3.yzx + 19.19);
    return frac(float3((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y, (p3.y + p3.z) * p3.x));
}

float3 ExpandNormals(float3 n){
    n.xyz = n.xyz * 2.0 - 1.0;
    return n;
}

float2 RotateVec2(float2 v, float rotation, float2 center){
    float2 Rotated = v - center;
    float s, c;
    sincos(rotation, s, c);
    Rotated = float2(Rotated.x * c + Rotated.y * s, Rotated.y * c - Rotated.x * s);
    return Rotated + center;
}

RandomUV RandomUVTransforms(float2 uv, float2 center, float2 rotationMinMax, float2 scaleMinMax, float2 seed)
{
    RandomUV randomUV;

    // COMPUTE RANDOM VALUES
    float3 hashRand = hash23(seed);
    float rotation = lerp(radians(rotationMinMax.x), radians(rotationMinMax.y), hashRand.x);
    float scale = lerp(scaleMinMax.x, scaleMinMax.y, hashRand.z);
    float2 offset = hashRand.xy;

    // ROTATION
    float2 TransformedUV = RotateVec2(uv, rotation, center);
    
    // SCALE, CENTER, & OFFSET
    TransformedUV *= scale;
    TransformedUV += center + offset;

    randomUV.TransformedUV = TransformedUV;
    randomUV.Rotation = TAU - rotation;
    
    return randomUV;
}

HexGrid CreateHexGrid(float2 inUV, float hexSize, float power)
{
    HexGrid grid;
    
    float2 uv = inUV * hexSize;
    float a = 1.732 * 0.5;
    float ra = rcp(a);

    float2 skewUv = float2(uv.x - uv.y * (0.5 / a), uv.y * ra);
    skewUv *= 0.5;

    float2 frac_uv = skewUv - floor(skewUv); 
    float2 uv_floor = floor(skewUv);
    float s = uv_floor.x - uv_floor.y;

    float3 square = float3(s, s, s) + float3(0, 1, 2);
    square *= rcp(3.0);
    square += 1.666667;
    square = round(frac(square));

    float ta = frac_uv.x + frac_uv.y - 1.0;
    float2 tb = 1.0 - frac_uv.yx;
    float2 t = (ta > 0.0) ? tb : frac_uv;

    float step_ta = (ta > 0.0) ? 1.0 : 0.0;
    float3 step_ta3 = float3(step_ta, step_ta, step_ta);

    float3 id = step_ta3 * square;
    grid.IdX = uv_floor + square.xy + id.zz;
    grid.IdY = uv_floor + square.zx + id.yy;
    grid.IdZ = uv_floor + square.yz + id.xx;

    grid.Weight = float3(abs(ta), t.x, t.y);
    grid.Weight = float3(dot(grid.Weight, square.zxy), dot(grid.Weight, square.yzx), dot(grid.Weight, square));
    grid.Weight = pow(grid.Weight, power);
    grid.Weight /= dot(grid.Weight, float3(1, 1, 1));

    return grid;
}

void StochasticSampling_float(float2 inUV, float hexSize, float tiling, float power, UnityTexture2D BCO, UnityTexture2D NS, UnitySamplerState Sampler, out float3 BC, out float AO, out float Smoothness, out float3 Normals)
{
    HexGrid grid = CreateHexGrid(inUV, hexSize, power);
    float3 weight = grid.Weight;

    float2 center = float2(0.5, 0.5);
    float2 rotationMinMax = float2(-180, 180);
    float2 scaleMinMax = float2(0.8, 1.2);

    RandomUV randomA = RandomUVTransforms(inUV * tiling, center, rotationMinMax, scaleMinMax, grid.IdX);
    RandomUV randomB = RandomUVTransforms(inUV * tiling, center, rotationMinMax, scaleMinMax, grid.IdY);
    RandomUV randomC = RandomUVTransforms(inUV * tiling, center, rotationMinMax, scaleMinMax, grid.IdZ);

    float4 BCO_A = SAMPLE_TEXTURE2D(BCO, Sampler, randomA.TransformedUV);
    float4 BCO_B = SAMPLE_TEXTURE2D(BCO, Sampler, randomB.TransformedUV);
    float4 BCO_C = SAMPLE_TEXTURE2D(BCO, Sampler, randomC.TransformedUV);

    float4 NS_A = SAMPLE_TEXTURE2D(NS, Sampler, randomA.TransformedUV);
    float4 NS_B = SAMPLE_TEXTURE2D(NS, Sampler, randomB.TransformedUV);
    float4 NS_C = SAMPLE_TEXTURE2D(NS, Sampler, randomC.TransformedUV);

    // EXPAND NORMALS
    float3 N_A = ExpandNormals(NS_A.xyz);
    float3 N_B = ExpandNormals(NS_B.xyz);
    float3 N_C = ExpandNormals(NS_C.xyz);

    // ROTATE NORMALS XY only, Z preserved
    N_A = float3(RotateVec2(N_A.xy, randomA.Rotation, float2(0,0)), N_A.z);
    N_B = float3(RotateVec2(N_B.xy, randomB.Rotation, float2(0,0)), N_B.z);
    N_C = float3(RotateVec2(N_C.xy, randomC.Rotation, float2(0,0)), N_C.z);

    // OUTPUT
    float4 OutBCO = BCO_A * weight.r + BCO_B * weight.g + BCO_C * weight.b;
    BC = OutBCO.xyz;
    AO = OutBCO.w;
    Smoothness = NS_A.w * weight.r + NS_B.w * weight.g + NS_C.w * weight.b;
    Normals = N_A * weight.r + N_B * weight.g + N_C * weight.b;
}