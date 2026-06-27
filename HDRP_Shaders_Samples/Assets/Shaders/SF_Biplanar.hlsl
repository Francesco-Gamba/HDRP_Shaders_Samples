// Biplanar. Shader Graph Custom Function, a two-fetch alternative to triplanar.
// Ranks the three world axes by normal alignment and samples only the dominant two,
// remapping weights to drop the third projection cleanly at the cube-corner boundary.
// SampleGrad preserves mips across seams. Normals reoriented by swizzle (approximate;
// reduced strength hides the error) see notes for the RNM upgrade path.

void Biplanar_float(
    UnityTexture2D BCO, UnityTexture2D NS, 
    UnitySamplerState Sampler,
    float3 worldPosition, float3 normalsWS,
    float3 tangentWS, float3 bitangentWS,
    float tiling, float BiplanarBlending,
    float normalStrength,
    out float3 outColor, out float outAO,
    out float3 outNormals, out float outSmoothness,
    out float outMetalness)
{
    float3 p = worldPosition;
    float3 dx = ddx(p);
    float3 dy = ddy(p);

    p *= tiling;
    dx *= tiling;
    dy *= tiling;

    float3 n = abs(normalsWS);
    float3 axisSign = sign(normalsWS);

    int3 maximum = (n.x>n.y && n.x>n.z) ? int3(0,1,2) : 
                   (n.y>n.z)             ? int3(1,2,0) :
                                           int3(2,0,1) ;

    int3 minimum = (n.x<n.y && n.x<n.z) ? int3(0,1,2) : 
                   (n.y<n.z)             ? int3(1,2,0) :
                                           int3(2,0,1) ;
    
    int3 median = int3(3,3,3) - minimum - maximum;

    // Sample BCO
    float4 BCO_x = BCO.SampleGrad(Sampler, 
                              float2(p[maximum.y], p[maximum.z]), 
                              float2(dx[maximum.y], dx[maximum.z]), 
                              float2(dy[maximum.y], dy[maximum.z]));
                              
    float4 BCO_y = BCO.SampleGrad(Sampler, 
                              float2(p[median.y], p[median.z]), 
                              float2(dx[median.y], dx[median.z]),
                              float2(dy[median.y], dy[median.z]));

    // Sample NS
    float4 NS_x = NS.SampleGrad(Sampler, 
                              float2(p[maximum.y], p[maximum.z]), 
                              float2(dx[maximum.y], dx[maximum.z]), 
                              float2(dy[maximum.y], dy[maximum.z]));
                              
    float4 NS_y = NS.SampleGrad(Sampler, 
                              float2(p[median.y], p[median.z]), 
                              float2(dx[median.y], dx[median.z]),
                              float2(dy[median.y], dy[median.z]));

    // Compute weights
    float2 weight = float2(n[maximum.x], n[median.x]);
    weight = saturate((weight - 0.5773) / (1.0 - 0.5773));
    weight = pow(weight, BiplanarBlending);

    // Blend BCO
    float4 BCO_blend = (BCO_x * weight.x + BCO_y * weight.y) / (weight.x + weight.y);

    // Unpack both normal samples
    float3 nm_x = NS_x.rgb * 2.0 - 1.0;
    float3 nm_y = NS_y.rgb * 2.0 - 1.0;
    
    // Scale down XY to reduce intensity
    nm_x.xy *= normalStrength;
    nm_y.xy *= normalStrength;

    // Reorient each normal sample into world space based on which axis it was projected from.
    // maximum.x tells us which world axis (0=X, 1=Y, 2=Z) this projection faces,
    // so we swizzle accordingly — same technique as the triplanar shader.
    float3 worldNM_x, worldNM_y;

    if (maximum.x == 0)      // X-facing projection
        worldNM_x = float3(nm_x.z * axisSign.x, nm_x.y, nm_x.x);
    else if (maximum.x == 1) // Y-facing projection
        worldNM_x = float3(nm_x.x, nm_x.z * axisSign.y, nm_x.y);
    else                     // Z-facing projection
        worldNM_x = float3(nm_x.x, nm_x.y, nm_x.z * axisSign.z);

    if (median.x == 0)
        worldNM_y = float3(nm_y.z * axisSign.x, nm_y.y, nm_y.x);
    else if (median.x == 1)
        worldNM_y = float3(nm_y.x, nm_y.z * axisSign.y, nm_y.y);
    else
        worldNM_y = float3(nm_y.x, nm_y.y, nm_y.z * axisSign.z);

    // Blend in world space then convert to tangent space
    float3 blendedNormalWS = normalize(worldNM_x * weight.x + worldNM_y * weight.y);

    float3x3 worldToTangent = float3x3(tangentWS, bitangentWS, normalsWS);
    float3 blendedNormalTS = normalize(mul(worldToTangent, blendedNormalWS));

    // Blend smoothness
    float smoothness = (NS_x.a * weight.x + NS_y.a * weight.y) / (weight.x + weight.y);

    // Composite
    outColor      = BCO_blend.rgb;
    outAO         = BCO_blend.a;
    outNormals    = blendedNormalTS;
    outSmoothness = smoothness;
    outMetalness  = 0.0;
}