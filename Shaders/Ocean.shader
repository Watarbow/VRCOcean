// FFT ocean surface. Lighting follows GodotOceanWaves' water.gdshader (Atlas GDC 2019 BSDF, GGX),
// with Schlick fresnel (F0 = 0.02) on the reflection probe / skybox.
// Up to 4 cascades; _DispTexN / _NormTexN / _CascadeN are set at runtime by OceanFFT (cascadeIndex N).
Shader "VRCOcean/Ocean"
{
    Properties
    {
        // Water colour comes from inherent optical properties (pure water + chlorophyll), not a colour pick.
        _Chlorophyll ("Chlorophyll (mg/m^3; 0.05 deep blue, 1 green coastal)", Range(0.01, 10)) = 0.2
        _SSSStrength ("Wave Crest Scattering", Range(0, 4)) = 1
        _FoamColor ("Foam Color", Color) = (0.8, 0.8, 0.8, 1)
        _Roughness ("Roughness", Range(0.01, 1)) = 0.4
        _NormalStrength ("Normal Strength", Range(0, 1)) = 1
        _DispScale ("Displacement Scale", Range(0, 2)) = 1
        // Per cascade (tileLength, displacementScale, normalScale, -), set at runtime by OceanFFT.
        _Cascade0 ("Cascade 0", Vector) = (0, 0, 0, 0)
        _Cascade1 ("Cascade 1", Vector) = (0, 0, 0, 0)
        _Cascade2 ("Cascade 2", Vector) = (0, 0, 0, 0)
        _Cascade3 ("Cascade 3", Vector) = (0, 0, 0, 0)
        [Header(Sun Glints)]
        _GlintIntensity ("Glint Intensity (1 = energy conserving)", Float) = 4
        _GlintCell ("Glint Cell Size (m)", Float) = 0.15
        _GlintSlope ("Glint Facet Slope", Range(0.01, 0.5)) = 0.08
        _GlintCone ("Glint Sun Cone (rad)", Range(0.005, 0.2)) = 0.08
        _GlintSpeed ("Glint Flicker Speed", Float) = 3
        _SunSheen ("Smooth Sun Highlight", Range(0, 1)) = 0.35
        _SpecMax ("Sun Highlight Max (HDR, keeps bloom sane)", Float) = 2
        [Header(Horizon)]
        _HorizonTilt ("Far Facets Lean To Viewer (darker horizon)", Range(0, 4)) = 1
        _HorizonFog ("Fog Distance Capped At Horizon (0 = off)", Range(0, 1)) = 1
        _FogSky ("Fog Colour From Sky Horizon (0 = scene fog colour)", Range(0, 1)) = 1
        _HazeHeight ("Haze Scale Height (m, thinner fog from above; 0 = off)", Float) = 1000
        [Header(Foam)]
        _FoamCell ("Foam Lace Cell (m)", Float) = 1.2
        [NoScaleOffset] _FoamSim ("Foam Sim (runtime)", 2D) = "black" {}
        _FoamSimArea ("Foam Sim Area (runtime: x, z, size, on)", Vector) = (0, 0, 1, 0)
        [NoScaleOffset] _FoamSimFar ("Far Foam Sim (runtime)", 2D) = "black" {}
        _FoamSimFarArea ("Far Foam Sim Area (runtime: x, z, size, on)", Vector) = (0, 0, 1, 0)
        _FoamStreaks ("Foam Left On Slicks (streaks)", Range(0, 1)) = 0.3
        _WhitecapCell ("Far Whitecap Cell (m, one cap at most)", Float) = 12
        _WhitecapDensity ("Far Whitecaps (share of cells breaking, 0 = none)", Range(0, 1)) = 0.01
        _WindDown ("Downwind (runtime: x, z)", Vector) = (0, -1, 0, 0)
        _SlickDamping ("Slick Smoothing (capillary damping)", Range(0, 1)) = 0.6
        _BubbleScatter ("Bubble Backscatter (1/m per unit)", Float) = 0.01
        [Header(Cloud Shadows (from VRCClouds CloudShadows, if present))]
        _CloudShadowStrength ("Cloud Shadow Strength", Range(0, 1)) = 1
        [Header(Ship Wake (runtime from OceanFFT cascade 0))]
        _Ship ("Ship (bow x, z, forward x, z)", Vector) = (0, 0, 0, 1)
        _ShipSize ("Ship (length, beam, speed, draft)", Vector) = (0, 0, 0, 0)
        _Wake ("Wake (kelvin height, bow hump, foam, on)", Vector) = (0, 0, 0, 0)
        _WakeTrail ("Wake Trail (foam, fresh, bubble, slick lifetime s)", Vector) = (4, 0.7, 6, 60)
        _MeshScale ("Mesh Scale (runtime)", Float) = 1
        _SkirtDistance ("Skirt Distance (runtime)", Float) = 45000
        [NoScaleOffset] _DispTex0 ("Disp 0", 2D) = "black" {}
        [NoScaleOffset] _DispTex1 ("Disp 1", 2D) = "black" {}
        [NoScaleOffset] _DispTex2 ("Disp 2", 2D) = "black" {}
        [NoScaleOffset] _DispTex3 ("Disp 3", 2D) = "black" {}
        [NoScaleOffset] _NormTex0 ("Normal/Foam 0", 2D) = "black" {}
        [NoScaleOffset] _NormTex1 ("Normal/Foam 1", 2D) = "black" {}
        [NoScaleOffset] _NormTex2 ("Normal/Foam 2", 2D) = "black" {}
        [NoScaleOffset] _NormTex3 ("Normal/Foam 3", 2D) = "black" {}
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" "Queue"="Geometry" }
        Pass
        {
            Tags { "LightMode"="ForwardBase" }
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile_fog
            #pragma target 4.5
            #include "UnityCG.cginc"
            #include "Lighting.cginc"

            sampler2D _DispTex0, _DispTex1, _DispTex2, _DispTex3;
            sampler2D _NormTex0, _NormTex1, _NormTex2, _NormTex3;
            float4 _Cascade0, _Cascade1, _Cascade2, _Cascade3;
            // Per cascade uv offset of the water flowing past the (fixed) ship, set by OceanFFT.
            float4 _Flow0, _Flow1, _Flow2, _Flow3;
            float4 _FoamLaceOffset;   // xy: the same flow in m for the foam lace, wrapped at 4096 cells
            #include "Ships.cginc"
            float4 _WakeTrail;
            float4 _FoamColor;
            float _Chlorophyll, _SSSStrength, _FoamCell;
            sampler2D _FoamSim, _FoamSimFar;
            float4 _FoamSimArea, _FoamSimFarArea;
            float _FoamStreaks, _SlickDamping, _BubbleScatter, _WhitecapCell, _WhitecapDensity;
            float4 _WindDown;
            float _Roughness, _NormalStrength, _DispScale, _MeshScale, _SkirtDistance;
            float _GlintIntensity, _GlintCell, _GlintSlope, _GlintCone, _GlintSpeed, _SunSheen, _SpecMax;
            float _HorizonTilt, _HorizonFog, _FogSky, _HazeHeight;
            // Cloud shadow map published by VRCClouds' CloudShadows (globals; unset = no clouds).
            // Area: centre x, z, size (0 = no map), sea level y. R = sun transmittance at sea level.
            sampler2D _UdonCloudShadowMap;
            float4 _UdonCloudShadowArea;
            float _CloudShadowStrength;

            float CloudShadow(float3 p, float3 L)
            {
                if (_UdonCloudShadowArea.z <= 0.0) return 1.0;
                // Follow the sun ray down to the map's sea level.
                float2 xz = p.xz - L.xz / max(L.y, 0.05) * (p.y - _UdonCloudShadowArea.w);
                float2 uv = (xz - _UdonCloudShadowArea.xy) / _UdonCloudShadowArea.z + 0.5;
                float2 e = abs(uv - 0.5) * 2.0;
                float edge = smoothstep(0.8, 1.0, max(e.x, e.y));   // fade out before the map ends
                float t = lerp(tex2Dlod(_UdonCloudShadowMap, float4(uv, 0, 0)).r, 1.0, edge);
                return lerp(1.0, t, _CloudShadowStrength);
            }

            struct appdata
            {
                float4 vertex : POSITION;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct v2f
            {
                float4 pos : SV_POSITION;
                float3 worldPos : TEXCOORD0;
                float2 baseXZ : TEXCOORD1;      // undisplaced world XZ
                float waveHeight : TEXCOORD2;
                UNITY_VERTEX_OUTPUT_STEREO
            };

            // Centre-eye camera position so both eyes displace identically.
            float3 CameraPos()
            {
                #if defined(USING_STEREO_MATRICES)
                return (unity_StereoWorldSpaceCameraPos[0] + unity_StereoWorldSpaceCameraPos[1]) * 0.5;
                #else
                return _WorldSpaceCameraPos;
                #endif
            }

            // Godot fades displacement after 150 m for an 88 m tile; scale that with the tile so
            // the long swell cascades stay displaced out to kilometres.
            float3 CascadeDisp(sampler2D tex, float4 c, float4 f, float2 xz, float dist)
            {
                float tile = max(c.x, 1.0);
                // Mip matching the vertex spacing (0.25 m at scale 1) so short waves don't alias.
                float lod = max(0.0, log2(0.25 * _MeshScale * 256.0 / tile));
                float k = 88.0 / tile;
                float falloff = min(exp(-(dist * k - 150.0) * 0.007), 1.0);
                return tex2Dlod(tex, float4(xz / tile - f.xy, 0, lod)).xyz * c.y * falloff;
            }

            // One Kelvin source (stationary phase): behind a point moving at V, every point inside the
            // 19.47 deg wedge sees two waves, transverse and divergent. With tau = |c| / a their
            // directions are tan(theta) = the roots of 2 tau t^2 - t + tau = 0 (pointing away from the
            // point's side), k = g / (V cos theta)^2. Returns the height and adds the gradient; waves
            // shorter than 2 pi / kMax are faded out (they would only alias).
            float KelvinSource(Ship s, float2 p, float amp, float kMax, inout float2 grad)
            {
                float2 aft = s.aft;
                float2 side = float2(-aft.y, aft.x);
                float a = dot(p, aft);
                float c = dot(p, side);
                float ac = abs(c);
                float tau = ac / max(a, 1e-3);
                float D = 1.0 - 8.0 * tau * tau;
                float r = length(p);
                // Fade across the wedge edge, in from the source, and out over kilometres.
                float fade = saturate(1.0 + D * 10.0) * smoothstep(0.0, 20.0, a) * exp(-r * 3e-4);
                float h = 0.0;
                UNITY_BRANCH if (fade > 0.0)
                {
                    float sd = sqrt(max(D, 0.0));
                    float k0 = 9.81 / max(s.V * s.V, 1e-2);
                    // ~1/sqrt(r), sharpening onto the cusp line where the two waves merge.
                    float env = amp * fade * sqrt(s.L / (s.L + r)) * pow(1.02 / (max(D, 0.0) + 0.02), 0.25);
                    float2 tt = float2(2.0 * tau / (1.0 + sd), (1.0 + sd) / max(4.0 * tau, 1e-4));
                    float2 wt = float2(0.6, 1.0);   // transverse, divergent
                    [unroll] for (int i = 0; i < 2; i++)
                    {
                        float t = tt[i];
                        float sec2 = 1.0 + t * t;
                        float k = k0 * sec2;
                        // A hull of draft T radiates little at wavelengths shorter than it (Michell: e^-kT),
                        // so the short divergent waves deep in the wedge stay small and the cusp stands out.
                        float e = env * wt[i] * exp(-(k - k0) * s.T) * saturate(2.0 - k / kMax);
                        float kc = k * rsqrt(sec2);
                        float ph = kc * (a - ac * t);
                        h += e * cos(ph);
                        grad -= e * sin(ph) * kc * (aft - side * (t * sign(c)));
                    }
                }
                return h;
            }

            // Ship wake, analytic: the ship stays put and the water flows past at _ShipSize.z, so the
            // pattern is fixed to the hull. Kelvin waves from the bow and (weaker, trough first) the
            // stern, plus the water piled up at the bow. Height in m; gradient added to grad.
            float ShipWake(float2 xz, float kMax, inout float2 grad)
            {
                float h = 0.0;
                [unroll] for (int i = 0; i < SHIP_COUNT; i++)
                {
                    Ship s = GetShip(i);
                    UNITY_BRANCH if (s.on > 0.5)
                    {
                        float2 aft = s.aft;
                        float2 side = float2(-aft.y, aft.x);
                        float2 p = xz - s.bow;
                        h += KelvinSource(s, p, s.kelvin, kMax, grad)
                           + KelvinSource(s, p - aft * s.L, -0.6 * s.kelvin, kMax, grad);
                        float hb = max(0.5 * s.B, 1.0);
                        float a = dot(p, aft) / 15.0;
                        float c = dot(p, side) / hb;
                        float hump = s.hump * exp(-a * a - c * c);
                        grad -= hump * 2.0 * (a / 15.0 * aft + c / hb * side);
                        h += hump;
                    }
                }
                return h;
            }

            // int_0^x e^(-s/m) e^(-(x-s)/n) ds: what a source fading over m leaves after decaying over n.
            float Trail(float x, float m, float n)
            {
                n = (abs(n - m) < 0.01 * m) ? 1.01 * m : n;
                return (exp(-x / n) - exp(-x / m)) / (1.0 / m - 1.0 / n);
            }

            // The stern wake's steady state in the foam sim (FoamSim.shader WakeFoam, carried aft at
            // the ship's speed and decaying with the sim's lifetimes), in closed form. Stands in for
            // the sim where it doesn't reach: the sims follow the player, so a ship kilometres away
            // would otherwise have no trail at all. RGBA as the sim.
            // The bow wave: white water hugging the fore hull, and the breaking crest peeling off it
            // at ~30 deg (wider than the 19.5 deg Kelvin cusp: close in, the bow wave is steep
            // enough to break). Fades over half a ship length; grows with the square of the speed.
            float BowFoam(Ship sh, float a, float c, float V)
            {
                float L = sh.L;
                float hw = 0.5 * sh.B * saturate(a / (0.2 * L));   // the hull tapers to the stem
                float crest = 2.0 + 0.58 * a;
                float w = 3.0 + 0.1 * a;
                float d = (c - crest) / w;
                float s = saturate(V / 10.0);
                // max: far ahead of the bow a is kilometres negative, and exp would overflow (inf * 0 = NaN, black).
                float arm = exp(-d * d) * exp(-max(a, 0.0) / (0.15 * L)) * smoothstep(-6.0, 2.0, a);
                float hug = smoothstep(-1.0, 1.5, c - hw) * smoothstep(16.0, 3.0, c - hw)
                          * smoothstep(-5.0, 3.0, a) * smoothstep(0.4 * L, 0.1 * L, a);
                return 1.6 * s * s * (arm + hug);
            }

            float4 ShipTrail(Ship sh, float2 xz)
            {
                float V = sh.V;
                if (sh.on < 0.5 || V < 0.1) return 0.0;
                float2 aft = sh.aft;
                float2 p = xz - sh.bow;
                float x = dot(p, aft) - sh.L;
                float c = abs(dot(p, float2(-aft.y, aft.x)));
                float bow = BowFoam(sh, x + sh.L, c, V);
                float half = 0.5 * sh.B * (0.7 + 0.06 * sqrt(max(x, 0.0)));
                float w = smoothstep(half, 0.3 * half, c) * smoothstep(-20.0, 0.0, x);
                if (w <= 0.0) return float4(bow, bow, 2.0 * bow, 0.0);
                x = max(x, 0.0);
                // churn per m of water passing, thinned as the wake spreads (FoamSim WakeSpread)
                float g = w * sh.foam * saturate(V / 5.0) / V * 0.7 / (0.7 + 0.06 * sqrt(x));
                float lf = V * _WakeTrail.x, lg = V * _WakeTrail.y, lb = V * _WakeTrail.z, ls = V * _WakeTrail.w;
                float4 s;
                s.r = g * Trail(x, 150.0, lf);
                s.g = g * Trail(x, 150.0, lg);
                s.b = 2.0 * g * Trail(x, 150.0, lb);
                // slick: the foam decaying at r / lf per m, kept over ls
                s.a = g / lf * (Trail(x, lf, ls) - Trail(x, 150.0, ls)) / (1.0 / 150.0 - 1.0 / lf);
                s.rgb += float3(bow, bow, 2.0 * bow);
                return s;
            }

            float4 WakeTrail(float2 xz)
            {
                float4 t = 0.0;
                [unroll] for (int i = 0; i < SHIP_COUNT; i++) t += ShipTrail(GetShip(i), xz);
                return min(t, 4.0);
            }

            v2f vert (appdata v)
            {
                v2f o;
                UNITY_SETUP_INSTANCE_ID(v);
                UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
                // Skirt: clipmap_high spans +-256; its outer ring is pushed out to the far clip.
                float4 ov = v.vertex;
                if (max(abs(ov.x), abs(ov.z)) > 255.5) ov.xz *= _SkirtDistance / (256.0 * _MeshScale);
                float3 wp = mul(unity_ObjectToWorld, ov).xyz;
                o.baseXZ = wp.xz;
                float dist = length(wp.xz - CameraPos().xz);
                float3 d = CascadeDisp(_DispTex0, _Cascade0, _Flow0, wp.xz, dist)
                         + CascadeDisp(_DispTex1, _Cascade1, _Flow1, wp.xz, dist)
                         + CascadeDisp(_DispTex2, _Cascade2, _Flow2, wp.xz, dist)
                         + CascadeDisp(_DispTex3, _Cascade3, _Flow3, wp.xz, dist);
                float2 wakeGrad = 0;
                d.y += ShipWake(wp.xz, 1.5 / _MeshScale, wakeGrad);
                // The skirt's 45 km triangles stretch whatever displacement the last ring (252 m) has
                // across the horizon, and every 4 m snap swaps which vertices that is. Fade to zero
                // before the ring, by camera distance so the fade itself doesn't jump with the snap
                // (12 m margin: 4 m snap + head-to-camera lag at speed).
                float2 camOff = abs(wp.xz - CameraPos().xz) / _MeshScale;
                d *= _DispScale * smoothstep(240.0, 176.0, max(camOff.x, camOff.y));
                wp += d;
                o.waveHeight = d.y;
                o.worldPos = wp;
                o.pos = UnityWorldToClipPos(wp);
                return o;
            }

            // Adds this cascade's gradient, foam and LEADR slope variance: B holds the mean squared
            // slope per axis, so after mip filtering B - (mean slope)^2 is exactly the slope
            // variance the filtering averaged away.
            void CascadeSurface(sampler2D tex, float4 c, float4 f, float2 xz, float dist,
                                inout float2 grad, inout float foam, inout float slopeVar)
            {
                float tile = max(c.x, 1.0);
                float4 nf = tex2D(tex, xz / tile - f.xy);   // xy = gradient, z = mean squared slope, w = foam
                grad += nf.xy * c.z;
                slopeVar += max(0.0, nf.z - 0.5 * dot(nf.xy, nf.xy)) * c.z * c.z;
                foam += smoothstep(0.0, 1.0, nf.w * 0.75) * exp(-dist * 0.0075 * 88.0 / tile) * step(0.001, c.z);
            }

            // Beckmann NDF; alpha2 = 2 * slope variance per axis.
            float Beckmann(float nh, float alpha2)
            {
                float c2 = max(nh * nh, 1e-4);
                return exp(-(1.0 - c2) / (c2 * alpha2)) / (UNITY_PI * alpha2 * c2 * c2);
            }

            float GGX(float nh, float a)
            {
                float a2 = a * a;
                float d = 1.0 + (a2 - 1.0) * nh * nh;
                return a2 / (UNITY_PI * d * d);
            }

            float SmithMask(float cosTheta, float a)
            {
                float t = cosTheta / (a * sqrt(max(1.0 - cosTheta * cosTheta, 1e-5)));
                return t < 1.6 ? (1.0 - 1.259 * t + 0.396 * t * t) / (3.535 * t + 2.181 * t * t) : 0.0;
            }

            // Dave Hoskins, "Hash without Sine" (MIT)
            float4 Hash42(float2 p)
            {
                float4 p4 = frac(float4(p.xyxy) * float4(0.1031, 0.1030, 0.0973, 0.1099));
                p4 += dot(p4, p4.wzxy + 33.33);
                return frac((p4.xxyz + p4.yzzw) * p4.zywx);
            }

            // Worley F2 - F1: 0 on cell borders, ~1 in cell centres.
            float CellEdge(float2 p)
            {
                float2 c = floor(p);
                float2 f = frac(p);
                float d1 = 8.0, d2 = 8.0;
                for (int y = -1; y <= 1; y++)
                for (int x = -1; x <= 1; x++)
                {
                    float2 o = float2(x, y);
                    float2 r = o + 0.1 + 0.8 * Hash42(c + o - 4096.0 * floor((c + o) / 4096.0)).xy - f;
                    float d = dot(r, r);
                    if (d < d1) { d2 = d1; d1 = d; } else if (d < d2) d2 = d;
                }
                return sqrt(d2) - sqrt(d1);
            }

            // Foam fills the bubble-cell borders first and the cell centres last, so as the
            // amount decays fresh white patches open up into lace. Once the cells shrink below a
            // pixel the pattern is replaced by its mean coverage (no shimmer).
            float FoamLace(float2 xz, float footprint, float amount)
            {
                float mean = saturate(amount) * saturate(0.3 + amount);
                float aa = saturate(footprint / (0.5 * _FoamCell));
                // Most of the ocean has no foam: skip the 27 hashes there (and where cells are sub-pixel).
                float result = mean;
                UNITY_BRANCH if (amount >= 0.02 && aa < 1.0)
                {
                    float n = 1.3 * (0.5 * CellEdge(xz / _FoamCell) + 0.3 * CellEdge(xz / (0.37 * _FoamCell) + 17.0)
                                   + 0.2 * CellEdge(xz / (0.13 * _FoamCell) + 5.0));
                    // Thin foam is also see-through, not just broken up.
                    float lace = saturate((0.8 * amount - n) * 4.0) * saturate(0.3 + amount);
                    result = lerp(lace, mean, aa);
                }
                return result;
            }

            // The ship's wake is not a uniform sheet: propeller boils well up as turquoise patches
            // ringed by foam, and the shear draws the older foam out into streaks along the wake.
            // In wake-aligned coordinates (moving with the water); x = boils, y = streaks (0 on a line).
            float2 WakeBreakup(float2 xz)
            {
                float2 aft = -_Ship.zw;
                float2 q = float2(dot(xz, aft), dot(xz, float2(-aft.y, aft.x)));
                float boil = 0.65 * CellEdge(q / float2(28.0, 18.0)) + 0.35 * CellEdge(q / float2(10.0, 7.0) + 31.0);
                // Streaks meander and fade in and out along their length, so they don't read as ruled lines.
                float streak = CellEdge(q / float2(55.0, 7.0) + float2(0.0, 0.8 * sin(q.x * 0.013)) + 57.0) + 0.25 * boil;
                return float2(boil, streak);
            }

            // Past the near sim the foam only exists as 8 m texels; drawn as-is it reads as soft grey
            // blotches. Instead open water gets sparse whitecaps: at most one per cell, a crest-long
            // ellipse (across the wind) with a torn, pixel-sharp rim. Each cell breaks now and then
            // (a few seconds, at a new spot each time); _WhitecapDensity is the share of cells
            // breaking at once, and the far sim's foam raises it where the sea has been breaking.
            // Cells grow with the pixel footprint in power-of-two steps (as the glints do), so far
            // caps stay a few px wide instead of shimmering, and coverage stays the same.
            // ponytail: caps pop when the camera crosses a lod step; crossfade two lods if it shows.
            float FarWhitecaps(float2 xz, float footprintMin, float amount)
            {
                float lod = max(0.0, ceil(log2(max(footprintMin, 1e-4) * 40.0 / _WhitecapCell)));
                float2 w = _WindDown.xy;
                float2 p = float2(dot(xz, w), dot(xz, float2(-w.y, w.x)));   // along, across the wind
                float2 cs = _WhitecapCell * exp2(lod) * float2(0.5, 1.0);
                float2 c = floor(p / cs);
                c = c - 4096.0 * floor(c / 4096.0) + lod * 131.0;
                float4 h = Hash42(c + 71.0);
                float t = _Time.y / (4.0 + 4.0 * h.x) + h.y;   // a 4-8 s cycle per cell
                float4 hc = Hash42(c + 53.0 * frac(floor(t) / 64.0) * 64.0 + 19.0);   // this cycle's cap
                // sqrt: far sim foam is mostly < 0.01 with rare peaks.
                float breaking = step(hc.x, _WhitecapDensity * (1.0 + 8.0 * sqrt(max(amount, 0.0))));
                // Bursts open in the first tenth of the cycle, then shrinks away.
                float life = frac(t);
                float size = breaking * saturate(life * 10.0) * (1.0 - life);
                float halfLen = cs.y * (0.08 + 0.27 * hc.w * hc.w);   // mostly small caps, a few long ones
                float2 q = (frac(p / cs) - (0.35 + 0.3 * hc.yz)) * cs / halfLen;   // in cap half-lengths
                float d = length(q / float2(0.25, 1.0));
                float fw = max(fwidth(d), 1e-4);   // outside the branch: derivatives need every pixel
                float result = 0.0;
                UNITY_BRANCH if (size > 0.0)
                {
                    // Torn rim from cells a fifth of the cap long.
                    float n = CellEdge(q * 5.0 + hc.zw * 64.0);
                    float rim = saturate((sqrt(size) - d - 0.6 * (0.45 - n)) / fw);
                    // Brightest where it breaks (the downwind front); thins to streaks inside as it ages.
                    result = rim * lerp(0.75, 1.0, saturate(0.5 + 2.0 * q.x))
                           * lerp(1.0, saturate(0.3 + 2.5 * n), saturate(life * 1.5));
                }
                return result;
            }

            // Stochastic sun glints: every cell holds one capillary facet with a random, slowly
            // rotating slope. Only facets that mirror the sun light up, as round dots. Further away
            // the cells grow with the pixel footprint (power-of-two steps so nothing swims) and the
            // sun cone widens to stand in for the many facets per cell, so far glints merge into a
            // continuous glitter path. Returns radiance relative to the light colour.
            float SunGlint(float2 xz, float footprint, float3 N, float3 V, float3 L, float slope, out float lod)
            {
                lod = max(0.0, ceil(log2(max(footprint, 1e-4) / _GlintCell)));
                float cs = _GlintCell * exp2(lod);
                float2 cell = floor(xz / cs);
                float4 h = Hash42(fmod(cell, 4096.0) + lod * 131.0);
                float4 h2 = Hash42(h.zw * 917.0 + h.xy);
                float ang = h.x * 6.2831853 + _Time.y * _GlintSpeed * (h.y - 0.5) * 2.0;
                float r = slope * sqrt(-2.0 * log(max(h.z, 1e-4)));   // Rayleigh slope magnitude
                float3 n = normalize(N + float3(r * cos(ang), 0.0, r * sin(ang)));
                float cone = _GlintCone * exp2(lod * 0.5);
                float cosCone = cos(min(cone, 1.2));
                float t = saturate((dot(reflect(-V, n), L) - cosCone) / (1.0 - cosCone));
                // Round dot at a random spot in the cell, never below 1.5 px (no shimmer). A cell stands
                // for all the facets inside it, so its mean brightness is held at 1/4 of the cone
                // radiance whatever size the dot is drawn at: bigger dot -> dimmer dot.
                float rWorld = 0.18 * cs;
                float r2 = max(rWorld, 1.5 * footprint);
                float energy = 0.25 * cs * cs / min(UNITY_PI * r2 * r2, cs * cs);
                float d = length((frac(xz / cs) - (0.3 + 0.4 * h2.xy)) * cs) / r2;
                float dotMask = (saturate(1.0 - d) + 0.12 * saturate(1.0 - d / 3.0)) * energy;
                // Sun irradiance spread over the cone's solid angle: radiance = 1 / (pi cone^2),
                // ~260x the light colour at the default cone (a mirror image of the sun is that bright).
                return t * t * dotMask * _GlintIntensity / (UNITY_PI * cone * cone) * step(0.0, dot(n, L));
            }

            // Absorption a and backscatter bb (1/m) at R/G/B = 650/550/450 nm.
            // Pure water: Pope & Fry 1997, Smith & Baker 1981 (bb = b/2). Phytoplankton + CDOM:
            // Prieur & Sathyendranath 1981 (a_ph(440) = 0.06 C^0.65). Particle backscatter: Morel 1988.
            void WaterIOP(out float3 a, out float3 bb)
            {
                float C = max(_Chlorophyll, 0.01);
                a = float3(0.34, 0.0565, 0.0092) + 0.06 * pow(C, 0.65) * float3(0.36, 0.14, 1.12);
                float bbp = (0.002 + 0.01 * (0.5 - 0.25 * log10(C))) * 0.3 * pow(C, 0.62);
                bb = float3(0.0004, 0.00095, 0.00245) + bbp * float3(0.85, 1.0, 1.22);
            }

            // Remote-sensing reflectance of optically deep water, Lw / Ed (1/sr). Gordon et al. 1988 /
            // Lee et al. 2002: below-surface rrs from u = bb / (a + bb), then across the interface.
            float3 DeepWaterRrs(float3 a, float3 bb)
            {
                float3 u = bb / (a + bb);
                float3 rrs = (0.0949 + 0.0794 * u) * u;
                return 0.52 * rrs / (1.0 - 1.7 * rrs);
            }

            fixed4 frag (v2f i) : SV_Target
            {
                float3 V = normalize(_WorldSpaceCameraPos - i.worldPos);
                float dist = length(i.worldPos.xz - _WorldSpaceCameraPos.xz);

                float2 grad = 0;
                float foam = 0;
                float slopeVar = 0;
                CascadeSurface(_NormTex0, _Cascade0, _Flow0, i.baseXZ, dist, grad, foam, slopeVar);
                CascadeSurface(_NormTex1, _Cascade1, _Flow1, i.baseXZ, dist, grad, foam, slopeVar);
                CascadeSurface(_NormTex2, _Cascade2, _Flow2, i.baseXZ, dist, grad, foam, slopeVar);
                CascadeSurface(_NormTex3, _Cascade3, _Flow3, i.baseXZ, dist, grad, foam, slopeVar);
                foam = saturate(foam);
                float footprint = max(length(ddx(i.baseXZ)), length(ddy(i.baseXZ)));
                // Wake normals per pixel: the skirt's 45 km triangles can't carry them from the vertices.
                ShipWake(i.baseXZ, min(1.5, 0.8 / max(footprint, 1e-3)), grad);
                // Persistent foam (sampled at the undisplaced position so it rides with the water
                // parcel): the near sim, the far sim past its edge, the per-tile foam past both.
                // RGBA = foam, fresh foam, bubbles, slick (FoamSim.shader).
                float2 suv = (i.baseXZ - _FoamSimArea.xy) / _FoamSimArea.z + 0.5;
                float2 e = abs(suv - 0.5) * 2.0;
                float nearW = saturate((1.0 - max(e.x, e.y)) * 5.0) * _FoamSimArea.w;
                float2 fuv = (i.baseXZ - _FoamSimFarArea.xy) / _FoamSimFarArea.z + 0.5;
                float2 fe = abs(fuv - 0.5) * 2.0;
                float farW = saturate((1.0 - max(fe.x, fe.y)) * 5.0) * _FoamSimFarArea.w;
                float simW = max(nearW, farW);
                // Near: half from a ~2 m blur so patches fray out into lace instead of ending at a hard edge.
                float4 sim = lerp(tex2D(_FoamSimFar, fuv),
                                  0.5 * (tex2D(_FoamSim, suv) + tex2Dbias(_FoamSim, float4(suv, 0, 2.0))), nearW);
                // The ship's trail in closed form: all of it past both sims, and a floor inside them,
                // where the cross-wind rows and resampling wear the slick away faster than it decays
                // (and water the sims scroll onto starts empty). The sim's frayed churn stays on top.
                float4 trail = WakeTrail(i.baseXZ);
                sim = max(lerp(trail, sim, simW), trail);
                simW = max(simW, saturate(max(trail.r, trail.a) * 20.0));
                float fresh = saturate(sim.g / max(sim.r, 1e-3));
                float slick = saturate(sim.a) * simW;
                // Fresh foam is dense; old foam thins to lace, and some stays on the slick rows as streaks.
                float2 laceXZ = i.baseXZ - _FoamLaceOffset.xy;
                // In the wake: foam on the boils' rims, turquoise in their middles; slick foam only on streaks.
                float boilMul = 1.0, streakMul = 1.0;
                float inWake = saturate(trail.r * 3.0 + trail.a * 2.0);
                UNITY_BRANCH if (inWake > 0.0)
                {
                    float2 br = WakeBreakup(laceXZ);
                    boilMul = lerp(1.0, lerp(1.5, 0.35, smoothstep(0.1, 0.65, br.x)), inWake);
                    streakMul = lerp(1.0, 1.3 * saturate(1.0 - br.y * 2.5), inWake);
                }
                // Saturating: dense foam (the stern's churn) tops out instead of painting a flat white sheet.
                float simFoam = 1.2 * (1.0 - exp(-sim.r * (1.0 + 0.5 * fresh))) * boilMul + sim.a * _FoamStreaks * streakMul;
                // Open water (far sim, per-tile foam past it): sparse whitecaps; the ship's trail
                // keeps its continuous lace. The near sim is drawn as lace throughout.
                float footprintMin = min(length(ddx(i.baseXZ)), length(ddy(i.baseXZ)));
                float caps = FarWhitecaps(laceXZ, footprintMin, lerp(foam, simFoam, farW));
                float open = max(caps, FoamLace(laceXZ, footprint, 1.2 * (1.0 - exp(-trail.r * 1.25)) * boilMul + trail.a * _FoamStreaks * streakMul));
                float nearFoam = 0.0;
                UNITY_BRANCH if (nearW > 0.0) nearFoam = FoamLace(laceXZ, footprint, simFoam);
                foam = lerp(open, nearFoam, nearW);
                // Slicks damp the capillary waves: smoother reflections, tighter glints.
                float damp = 1.0 - _SlickDamping * slick;
                grad *= _NormalStrength;
                slopeVar *= _NormalStrength * _NormalStrength;
                float3 N = normalize(float3(-grad.x, 1.0, -grad.y));
                // Reflections blur with the slopes filtering removed (alpha^2 = 2 var).
                float rough = saturate(sqrt(_Roughness * _Roughness * damp * damp + 2.0 * slopeVar));

                float nv = max(dot(N, V), 2e-5);
                // At grazing angles the eye only sees the facets tilted toward it (the rest are masked),
                // so the mean visible normal leans to the viewer: lower fresnel and a reflection of
                // higher, darker sky (Bruneton et al. 2010). The lean grows with the slopes the mips
                // filtered away, so near water (resolved slopes) is unchanged.
                float2 vxz = V.xz / max(length(V.xz), 1e-4);
                float3 Nr = normalize(N + float3(vxz.x, 0.0, vxz.y) * sqrt(2.0 * slopeVar) * _HorizonTilt * (1.0 - nv));
                float F = 0.02 + 0.98 * pow(1.0 - max(dot(Nr, V), 2e-5), 5.0);

                // Sky / probe reflection. Keep the ray above the horizon.
                float3 R = reflect(-V, Nr);
                R.y = max(R.y, 0.01);
                float4 env = UNITY_SAMPLE_TEXCUBE_LOD(unity_SpecCube0, R, rough * UNITY_SPECCUBE_LOD_STEPS);
                float3 refl = DecodeHDR(env, unity_SpecCube0_HDR);

                // Sun
                float3 L = normalize(_WorldSpaceLightPos0.xyz);
                // Sunlight through the clouds above this point.
                float3 sunCol = _LightColor0.rgb * CloudShadow(i.worldPos, L);
                float3 H = normalize(L + V);
                float nl = max(dot(N, L), 2e-5);
                float lightMask = SmithMask(nv, rough);
                float viewMask = SmithMask(nl, rough);
                float spec = F * GGX(max(dot(N, H), 0.0), rough) / (1.0 + lightMask + viewMask) / (4.0 * nv + 0.1);
                float glintLod;
                float Fh = 0.02 + 0.98 * pow(1.0 - saturate(dot(H, V)), 5.0);   // facet fresnel
                float glintSlope = _GlintSlope * damp;
                float glint = Fh * SunGlint(i.baseXZ, footprint, N, V, L, glintSlope, glintLod);
                // Far: one analytic sun-glint lobe over every facet in the pixel (capillary facets +
                // the wave slopes filtering removed), with the same sun/sky ratio as the glints.
                // Smith masking-shadowing keeps the lobe finite at grazing angles (1/nv alone explodes).
                float alpha2 = 2.0 * (glintSlope * glintSlope + slopeVar);
                float a = sqrt(alpha2);
                float G = 1.0 / (1.0 + SmithMask(nv, a) + SmithMask(nl, a));
                float lobe = Fh * Beckmann(max(dot(N, H), 0.0), alpha2) * G
                             / (4.0 * nv) * _GlintIntensity * step(0.0, dot(N, L));
                // Near: discrete glints + a soft sheen. They hand over once cells are several px wide.
                float w = saturate((glintLod - 2.0) / 3.0);
                spec = min(lerp(spec * _SunSheen + glint, lobe, w), _SpecMax);

                // Fake subsurface scattering (Atlas): brighter on the back side of tall waves.
                // Light through the thin crest: a few metres of water absorb the red.
                float3 absorb, bb;
                WaterIOP(absorb, bb);
                // Bubbles under the foam are large, spectrally flat scatterers: the water turns turquoise.
                // In open water only under the caps (and in the trail), not as 8 m turquoise blotches.
                // The propeller wash is far denser in bubbles than a whitecap: x4 in the ship's trail.
                bb += lerp(max(4.0 * trail.b, sim.b * saturate(2.0 * foam)), max(sim.b, 4.0 * trail.b), nearW) * simW * _BubbleScatter;
                float sssHeight = max(0.0, i.waveHeight + 2.5) * pow(max(dot(L, -V), 0.0), 4.0) * pow(0.5 - 0.5 * dot(L, N), 3.0);
                float sssNear = 0.5 * nv * nv;
                float3 sss = (sssHeight + sssNear) / (1.0 + lightMask) * _SSSStrength * 0.12 * exp(-4.0 * absorb);

                // Water-leaving radiance = Rrs * downwelling irradiance (sun on a level surface + sky).
                float3 Ed = sunCol * saturate(L.y) + UNITY_PI * ShadeSH9(float4(0, 1, 0, 1));
                float3 water = (DeepWaterRrs(absorb, bb) * Ed + sss * sunCol) * (1.0 - F) / 0.98;
                float3 foamCol = _FoamColor.rgb * lerp(0.85, 1.15, fresh) * (sunCol * nl + ShadeSH9(float4(N, 1.0)));

                float3 col = lerp(water, foamCol, foam) + (refl * F + spec * sunCol) * (1.0 - foam);
                #if defined(FOG_LINEAR) || defined(FOG_EXP) || defined(FOG_EXP2)
                // The skirt runs out to 45 km, but on the curved earth the sea ends at the horizon
                // (sqrt(2 R h): ~5 km from 2 m). Past that the plane would fog to a white band the
                // real sea never shows, so the fog distance stops there.
                float h = max(_WorldSpaceCameraPos.y - unity_ObjectToWorld._m13, 0.5);
                float fogDist = lerp(dist, min(dist, sqrt(2.0 * 6371000.0 * h)), _HorizonFog);
                // Haze thins with height (density ~ e^(-y/H)): from h above the sea the ray's mean
                // density is (1 - e^(-h/H)) / (h/H) of the sea-level one, so from a plane the sea clears up.
                float k = h / max(_HazeHeight, 1e-3);
                fogDist *= _HazeHeight > 0.0 ? (1.0 - exp(-k)) / k : 1.0;
                UNITY_CALC_FOG_FACTOR_RAW(fogDist);
                // Fade to the sky just above the horizon in this direction, so the sea meets the sky
                // instead of turning brighter than it (the scene fog colour is near white).
                float3 hz = normalize(float3(-V.x, 0.0, -V.z) + float3(0.0, 0.02, 0.0));
                float3 skyHz = DecodeHDR(UNITY_SAMPLE_TEXCUBE_LOD(unity_SpecCube0, hz, 0), unity_SpecCube0_HDR);
                col = lerp(lerp(unity_FogColor.rgb, skyHz, _FogSky), col, saturate(unityFogFactor));
                #endif
                return fixed4(col, 1.0);
            }
            ENDCG
        }
    }
}
