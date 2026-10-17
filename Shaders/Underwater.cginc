// Shared by Ocean.shader (the surface seen from below) and Underwater.shader (everything else seen
// from under the water). The including shader declares _DispTex0-3, _Cascade0-3, _Flow0-3,
// _DispScale, _Chlorophyll and _UnderwaterExposure.

// Absorption a, backscatter bb and total scatter b (1/m) at R/G/B = 650/550/450 nm.
// Pure water: Pope & Fry 1997, Smith & Baker 1981 (bb = b/2). Phytoplankton + CDOM:
// Prieur & Sathyendranath 1981 (a_ph(440) = 0.06 C^0.65). Particle backscatter: Morel 1988,
// ~1.8% of the particles' scattering (Petzold).
void WaterIOP(out float3 a, out float3 bb, out float3 b)
{
    float C = max(_Chlorophyll, 0.01);
    a = float3(0.34, 0.0565, 0.0092) + 0.06 * pow(C, 0.65) * float3(0.36, 0.14, 1.12);
    float3 bbw = float3(0.0004, 0.00095, 0.00245);
    float3 bbp = (0.002 + 0.01 * (0.5 - 0.25 * log10(C))) * 0.3 * pow(C, 0.62) * float3(0.85, 1.0, 1.22);
    bb = bbw + bbp;
    b = 2.0 * bbw + bbp / 0.0183;
}

float3 WaterDisp(float2 xz)
{
    float3 d = tex2Dlod(_DispTex0, float4(xz / max(_Cascade0.x, 1.0) - _Flow0.xy, 0, 0)).xyz * _Cascade0.y
             + tex2Dlod(_DispTex1, float4(xz / max(_Cascade1.x, 1.0) - _Flow1.xy, 0, 0)).xyz * _Cascade1.y
             + tex2Dlod(_DispTex2, float4(xz / max(_Cascade2.x, 1.0) - _Flow2.xy, 0, 0)).xyz * _Cascade2.y
             + tex2Dlod(_DispTex3, float4(xz / max(_Cascade3.x, 1.0) - _Flow3.xy, 0, 0)).xyz * _Cascade3.y;
    return d * _DispScale;
}

// How far the camera is below the surface (m, < 0 above it). The waves move water sideways too, so
// look up the water parcel that lands above the camera (one fixed-point step: error ~ slope^2).
// ponytail: leaves out the ship wake (Ocean.shader ShipWake); swimmers in the bow hump see it ~1 m off.
float CameraDepth(float seaLevel)
{
    float3 cam = _WorldSpaceCameraPos;
    float2 p = cam.xz - WaterDisp(cam.xz).xz;
    return seaLevel + WaterDisp(p).y - cam.y;
}

// Radiance of a long sight line under the water at this depth, relative to the downwelling
// irradiance Ed at the surface: the light the water scatters toward the eye, dimming with depth.
// Below-surface rrs (Lee et al. 2002); Ed decays at Kd ~ 1.3 (a + bb) (Gordon 1989, sun mid-sky).
float3 UnderwaterRadiance(float3 a, float3 bb, float depth)
{
    float3 u = bb / (a + bb);
    return (0.0949 + 0.0794 * u) * u * exp(-1.3 * (a + bb) * max(depth, 0.0));
}
