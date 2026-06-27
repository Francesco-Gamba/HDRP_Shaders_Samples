// TriplanarRocks.  Shader Graph Custom Function for UV-free environment surfaces.
// Three-projection triplanar blend (color + normal + smoothness) with scale-aware
// tiling, whiteout-blended base detail layer, and a slope-masked second layer
// (moss/snow) driven by the world-space rock normal. Normals reoriented per
// projection and composited in world space before tangent conversion.

struct TriplanarUV {
    float2 x, y, z;
};

struct AdditionalSurface{
    float3 color;
    float ao;
    float3 normals;
    float smoothness;
    float metalness;
    float mask;
};

TriplanarUV makeTriplanarUV(float3 worldPosition, float tiling)
{
    TriplanarUV triUv;
    triUv.x = worldPosition.zy * tiling; 
    triUv.y = worldPosition.xz * tiling;
    triUv.z = worldPosition.xy * tiling;
    return triUv;
}

float3 getTriplanarWeights(float3 normals, float blending)
{
    float3 weights = pow(abs(normals), blending);
    return weights / (weights.x + weights.y + weights.z);
}

float computeUpMask(float3 normals, float power){
    float mask = dot(normals, float3(0.0, 1.0, 0.0));
    return saturate(pow(saturate(mask), power));
}

float3 WhiteoutBlend(float3 n1, float3 n2)
{
    return normalize(float3(n1.xy + n2.xy, n1.z * n2.z));
}

void TriplanarRocks_float(
    float3 meshScale, float2 meshUv,
    UnityTexture2D Base_NO, 
    UnityTexture2D BCO, UnityTexture2D NS, 
    UnityTexture2D LayerBCO, UnityTexture2D LayerNS,
    UnitySamplerState Sampler,
    float3 worldPosition, float3 normalsWS,
    float3 tangentWS, float3 bitangentWS,
    float tiling, float tilingLayer, float blending,
    float detailStrength, float maskPower,
    out float3 outColor, out float outAO,
    out float3 outNormals, out float outSmoothness,
    out float outMetalness)
{
    //Base
    float avgScale = (meshScale.x + meshScale.y + meshScale.z) * 0.33;
    float4 base = SAMPLE_TEXTURE2D(Base_NO, Sampler, meshUv);
    float baseAo = base.w;
    float3 baseNormals = base.xyz * 2.0 - 1.0;

    //Compute weights and uvs
    float3 weights = getTriplanarWeights(normalsWS, blending);
    TriplanarUV uv  = makeTriplanarUV(worldPosition, tiling / avgScale);

    //sample color and ao
    float4 bcoX = SAMPLE_TEXTURE2D(BCO, Sampler, uv.x);
    float4 bcoY = SAMPLE_TEXTURE2D(BCO, Sampler, uv.y);
    float4 bcoZ = SAMPLE_TEXTURE2D(BCO, Sampler, uv.z);
    float4 blendedBCO = bcoX * weights.x + bcoY * weights.y + bcoZ * weights.z;

    //Sample normals and data
    float4 nsX = SAMPLE_TEXTURE2D(NS, Sampler, uv.x);
    float4 nsY = SAMPLE_TEXTURE2D(NS, Sampler, uv.y);
    float4 nsZ = SAMPLE_TEXTURE2D(NS, Sampler, uv.z);

    //Unpack detail normals
    float3 nmX = nsX.rgb * 2.0 - 1.0;
    float3 nmY = nsY.rgb * 2.0 - 1.0;
    float3 nmZ = nsZ.rgb * 2.0 - 1.0;
    nmX.xy *= detailStrength;
    nmY.xy *= detailStrength;
    nmZ.xy *= detailStrength;

    //Reorientation
    float3 axisSign = sign(normalsWS);
    float3 worldNM_X = float3(nmX.z * axisSign.x, nmX.y, nmX.x);
    float3 worldNM_Y = float3(nmY.x, nmY.z * axisSign.y, nmY.y);
    float3 worldNM_Z = float3(nmZ.x, nmZ.y, nmZ.z * axisSign.z);
    
    //Blending in world space
    float3 detailNormalWS = normalize(worldNM_X * weights.x + worldNM_Y * weights.y + worldNM_Z * weights.z);
    
    //Setup the additional surface layer - moss or snow
    AdditionalSurface layer;
    float2 uvLayer = worldPosition.xz * tilingLayer;
    float4 lBCO = SAMPLE_TEXTURE2D(LayerBCO, Sampler, uvLayer);
    float4 lNS = SAMPLE_TEXTURE2D(LayerNS, Sampler, uvLayer);
    layer.smoothness = lNS.w;
    layer.metalness = 0; 
    layer.color = lBCO.xyz; 
    layer.ao = lBCO.w;
    
    // Compute mask using world rock normal so it maps dynamically over details
    layer.mask = computeUpMask(detailNormalWS, maskPower);

    // Unpack top normal using only .rgb channels
    float3 layerNormalTS = lNS.rgb * 2.0 - 1.0;
    // Swizzle from Tangent to World space projection (Tangent Z -> World Y)
    float3 layerNormalWS = float3(layerNormalTS.x, layerNormalTS.z, layerNormalTS.y);

    float3 mixedWorldNormal = normalize(lerp(detailNormalWS, layerNormalWS, layer.mask));

    //All to tangent space
    float3x3 worldToTangent = float3x3(tangentWS, bitangentWS, normalsWS);
    float3 finalDetailTS = normalize(mul(worldToTangent, mixedWorldNormal));

    //Composite the surface
    outNormals    = WhiteoutBlend(baseNormals, finalDetailTS);
    outColor      = lerp(blendedBCO.rgb, layer.color, layer.mask);
    outAO         = lerp(blendedBCO.a * baseAo, layer.ao, layer.mask);
    outSmoothness = lerp(nsX.a * weights.x + nsY.a * weights.y + nsZ.a * weights.z, layer.smoothness, layer.mask);
    outMetalness  = lerp(0.0, layer.metalness, layer.mask);
}