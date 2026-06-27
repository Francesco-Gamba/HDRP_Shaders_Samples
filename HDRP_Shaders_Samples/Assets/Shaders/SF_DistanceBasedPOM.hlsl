// DistanceBasedPOM. Shader Graph Custom Function for parallax occlusion mapping
// with distance-adaptive quality. Step count and heightfield amplitude both fade
// smoothly with view distance, so close surfaces get full ray-marched depth while
// distant ones cheapen out gracefully. Linear search + last-segment interpolation.
// Selectable height channel. Outputs parallax-offset UVs.

float Remap(float In, float2 InMinMax, float2 OutMinMax)
{
    return OutMinMax.x + (In - InMinMax.x) * (OutMinMax.y - OutMinMax.x) / (InMinMax.y - InMinMax.x);
}

// Helper
float SampleChannel(UnityTexture2D HeightMap, UnitySamplerState Sampler, float2 uv, int channel)
{
    float4 s = SAMPLE_TEXTURE2D(HeightMap, Sampler, uv);
    if (channel == 1) return s.g;
    if (channel == 2) return s.b;
    if (channel == 3) return s.a;
    return s.r;
}

void DistanceBasedPOM_float(
    UnitySamplerState Sampler, UnityTexture2D HeightMap,
    float Channel, float2 MinMaxSteps, float2 MinMaxDistance,
    float2 InUvs, float Amplitude, float Tiling,
    float3 ViewDirWS, float3 TangentWS,
    float3 BitangentWS, float3 NormalWS,
    float3 ViewVectorWS, float AmplitudeFade,
out float2 OutUV)
{
    // Transform view direction to tangent space
    float3x3 worldToTangent = float3x3(TangentWS, BitangentWS, NormalWS);
    float3 viewDirTs = normalize(mul(worldToTangent, ViewDirWS));
 
    //smooth distance fade calculations for steps and amplitude
    float distanceFade = saturate(Remap(length(ViewVectorWS), MinMaxDistance, float2(0.0, 1.0)));
    float smoothFade = smoothstep(0.0,1.0,distanceFade);
    float stepsF = lerp(MinMaxSteps.y, MinMaxSteps.x, smoothFade);
    int steps = max((int)MinMaxSteps.x, (int)stepsF);
    float fadedAmplitude = Amplitude * (1.0 - smoothFade * AmplitudeFade);

    //calculate parallax dir using smooth amplitude fade
    float2 parallaxDir = (-viewDirTs.xy / viewDirTs.z) * fadedAmplitude;


    float verticalOffset  = 1.0 / steps;
    float2 horizontalOffset = parallaxDir / steps;

    float2 currentTexCoord = InUvs * float2(Tiling, Tiling);

    float sampledDepth     = 1.0 - SampleChannel(HeightMap, Sampler, currentTexCoord, (int)Channel);
    float sampledDepthPrev = sampledDepth;
    float currentLayerDepth = 0.0;
    float prevLayerDepth    = 0.0;
    float2 prevTexCoord     = currentTexCoord;

    [loop]
    for (int i = 0; i < steps; i++)
    {
        if (currentLayerDepth >= sampledDepth)
            break;

        prevTexCoord      = currentTexCoord;
        sampledDepthPrev  = sampledDepth;
        prevLayerDepth    = currentLayerDepth;

        currentTexCoord    += horizontalOffset;
        currentLayerDepth  += verticalOffset;

        sampledDepth = 1.0 - SampleChannel(HeightMap, Sampler, currentTexCoord, (int)Channel);
    }

    // Parallax occlusion interpolation between last two samples
    float afterDepth  = currentLayerDepth - sampledDepth;
    float beforeDepth = sampledDepthPrev - prevLayerDepth;
    float weight = afterDepth / max(0.00001, afterDepth + beforeDepth);

    OutUV = lerp(currentTexCoord, prevTexCoord, weight);
}