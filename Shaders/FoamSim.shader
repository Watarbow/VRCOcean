// Persistent foam (Crest style). One texel per world position around the player:
// state = last frame's state, advected by the surface drift, * decay + whitecapping where the
// summed Jacobian of all cascades drops below the threshold (the surface folds over).
// R = foam, G = fresh foam (short-lived, so G / R = freshness), B = subsurface bubbles,
// A = slick (surfactant left behind by decaying foam; long-lived, swept into wind rows).
// Driven by OceanFFT (cascade 0) with VRCGraphics.Blit, ping-ponging two ARGBHalf targets.
// The same pass runs twice: near (fine texels) and far (coarse texels, out to kilometres).
Shader "Hidden/VRCOcean/FoamSim"
{
    Properties
    {
        _MainTex ("Previous Foam", 2D) = "black" {}
    }
    SubShader
    {
        Cull Off ZWrite Off ZTest Always
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag
            #include "UnityCG.cginc"

            sampler2D _MainTex;
            sampler2D _DispTex0, _DispTex1, _DispTex2, _DispTex3;
            float4 _Cascade0, _Cascade1, _Cascade2, _Cascade3;
            float4 _Flow0, _Flow1, _Flow2, _Flow3;   // per cascade uv offset of the flowing water
            #include "Ships.cginc"
            float4 _Sim;        // (centre x, centre z, size, texel size)
            float4 _Shift;       // (uv offset from this frame's texture to last frame's, Jacobian texel, dt)
            float4 _FoamParams;  // (whitecap, grow per frame, foam decay per frame, reset)
            float4 _Decay;       // (fresh, bubble, slick decay per frame, -)
            float4 _Advect;      // (drift x, drift z in m/s, downwind x, z)
            float4 _Langmuir;    // (convergence m/s, row spacing m, -, -)

            float JacobianMinusOne(sampler2D tex, float4 c, float4 f, float2 xz)
            {
                // Mip matching the near sim texel: finer folds would only alias into speckles. The far
                // sim point-samples at that same detail; its decay averages the folds over time, so
                // its mean coverage matches the near sim's.
                float tile = max(c.x, 1.0);
                float lod = max(0.0, log2(_Shift.z * 256.0 / tile));
                return tex2Dlod(tex, float4(xz / tile - f.xy, 0, lod)).a * c.y;
            }

            // The turbulent wake spreads sideways as it ages: half width = hb (0.7 + 0.06 sqrt x) at x m
            // astern, so water at offset c moves out at c V d(half)/dx / half (self-similar widening).
            float2 WakeSpread(float2 xz)
            {
                float2 v = 0.0;
                [unroll] for (int i = 0; i < SHIP_COUNT; i++)
                {
                    Ship sh = GetShip(i);
                    if (sh.on < 0.5) continue;
                    float2 aft = sh.aft;
                    float2 side = float2(-aft.y, aft.x);
                    float2 p = xz - sh.bow;
                    float x = max(dot(p, aft) - sh.L, 1.0);
                    float c = dot(p, side);
                    float s = sqrt(x);
                    float half = 0.5 * sh.B * (0.7 + 0.06 * s);
                    float u = c * sh.V * 0.03 / (s * (0.7 + 0.06 * s));
                    v += side * u * smoothstep(1.6 * half, half, abs(c)) * smoothstep(0.0, 20.0, x);
                }
                return v;
            }

            // Langmuir circulation: cross-wind flow that converges onto rows parallel to the wind.
            // The rows meander along the wind and drift slowly, so they don't read as ruled lines.
            float2 Velocity(float2 xz)
            {
                float2 down = _Advect.zw;
                float2 cross = float2(-down.y, down.x);
                float a = dot(xz, down);
                float c = dot(xz, cross);
                float k = 6.2831853 / max(_Langmuir.y, 1.0);
                float ph = k * c + 1.5 * sin(k * a * 0.11 + _Time.y * 0.013) + 0.7 * sin(k * a * 0.037 - 1.3);
                return _Advect.xy - cross * (_Langmuir.x * sin(ph)) + WakeSpread(xz);
            }

            // Whitecapping where the first-order sum of the cascades' (J - 1) drops below the
            // threshold (the cross terms are second order).
            float Whitecap(float2 xz)
            {
                float jac = 1.0 + JacobianMinusOne(_DispTex0, _Cascade0, _Flow0, xz) + JacobianMinusOne(_DispTex1, _Cascade1, _Flow1, xz)
                                + JacobianMinusOne(_DispTex2, _Cascade2, _Flow2, xz) + JacobianMinusOne(_DispTex3, _Cascade3, _Flow3, xz);
                return max(0.0, _FoamParams.x - jac);
            }

            // Foam the ship churns up, per second: the turbulent wake behind the stern and the bow wave
            // breaking in a band just outside the waterline over the fore third. The flow carries it
            // aft; as it decays it leaves slick, the smooth band behind the ship.
            float ShipFoam(Ship sh, float2 xz)
            {
                if (sh.on < 0.5) return 0.0;
                float2 aft = sh.aft;
                float2 p = xz - sh.bow;
                float a = dot(p, aft);                              // m aft of the bow
                float cs = dot(p, float2(-aft.y, aft.x));
                float c = abs(cs);
                float L = sh.L;
                float hb = 0.5 * sh.B;
                // Turbulent wake: churned hardest at the stern, then widening (~sqrt of the distance)
                // with edges that wander in time, so the trail frays instead of running in rails.
                float x = a - L;                                    // m astern of the stern
                float half = hb * (0.7 + 0.06 * sqrt(max(x, 0.0)))
                           * (1.0 + 0.3 * sin(0.031 * x - _Time.y * 0.9 + sign(cs) * 2.0) * sin(0.017 * x + _Time.y * 0.5));
                float stern = smoothstep(-20.0, 0.0, x) * exp(-max(x, 0.0) / 150.0) * smoothstep(half, 0.3 * half, c);
                float hw = hb * saturate(a / (0.2 * L));            // the hull tapers to the stem
                float o = c - hw;
                float bow = smoothstep(-1.0, 2.0, o) * smoothstep(16.0, 4.0, o) * smoothstep(-5.0, 5.0, a) * smoothstep(0.35 * L, 0.1 * L, a);
                return (stern + bow) * sh.foam * saturate(sh.V / 5.0);
            }

            float WakeFoam(float2 xz)
            {
                float f = 0.0;
                [unroll] for (int i = 0; i < SHIP_COUNT; i++) f += ShipFoam(GetShip(i), xz);
                return f;
            }

            float4 frag (v2f_img i) : SV_Target
            {
                float2 xz = _Sim.xy + (i.uv - 0.5) * _Sim.z;
                float w = Whitecap(xz);
                // Far sim: a texel spans many folds, so one sample is noise; average four.
                UNITY_BRANCH if (_Sim.w > 2.0 * _Shift.z)
                {
                    float o = 0.25 * _Sim.w;
                    w = 0.25 * (w + Whitecap(xz + float2(o, 2.0 * o)) + Whitecap(xz + float2(-2.0 * o, o))
                                  + Whitecap(xz + float2(-o, -2.0 * o)));
                }
                // Semi-Lagrangian: read last frame's state where this water was dt ago.
                float2 uvPrev = i.uv + _Shift.xy - Velocity(xz) * _Shift.w / _Sim.z;
                float inside = all(uvPrev == saturate(uvPrev)) ? 1.0 : 0.0;
                float4 prev = tex2Dlod(_MainTex, float4(uvPrev, 0, 0)) * inside * (1.0 - _FoamParams.w);
                float gen = w * _FoamParams.y;
                float wake = WakeFoam(xz) * _Shift.w;
                float4 s;
                s.r = prev.r * _FoamParams.z + gen + wake;
                s.g = prev.g * _Decay.x + gen + wake;
                s.b = prev.b * _Decay.y + gen + 2.0 * wake;
                // Foam that decays this frame leaves its surfactant behind.
                s.a = prev.a * _Decay.z + prev.r * (1.0 - _FoamParams.z);
                return min(s, 4.0);
            }
            ENDCG
        }

        // Pass 1: bow spray particles (GPU, one texel pair per particle). The state is 2S x S
        // ARGBFloat: left half = position (world xyz, age s), right half = velocity (xyz, seed).
        // Texels (i, 0) hold ship i's bow state instead (Ships.cginc order): (water height at the
        // stem, slam, -, 1e4 = valid; read as a particle that is long dead, so it is never drawn).
        // Sources: the bow wave peeling off the stem (steady, grows with speed) and slamming,
        // when the sea rises fast against the (fixed) stem. Droplets fall under gravity with a
        // drag towards the air flowing past the ship, so the fine ones are blown aft.
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_img
            #pragma fragment frag
            #include "UnityCG.cginc"

            sampler2D _MainTex;
            float4 _MainTex_TexelSize;
            sampler2D _DispTex0, _DispTex1, _DispTex2, _DispTex3;
            float4 _Cascade0, _Cascade1, _Cascade2, _Cascade3;
            float4 _Flow0, _Flow1, _Flow2, _Flow3;
            #include "Ships.cginc"
            float4 _SprayParams;   // (dt, frame, amount, reset)
            float4 _SprayParams2;  // (slam threshold m/s, -, -, -)
            float4 _AirWind;       // m/s, the air past the fixed ship

            float Height(sampler2D tex, float4 c, float4 f, float2 xz)
            {
                float tile = max(c.x, 1.0);
                return tex2Dlod(tex, float4(xz / tile - f.xy, 0, 2)).y * c.y;
            }

            float WaterHeight(float2 xz)
            {
                return Height(_DispTex0, _Cascade0, _Flow0, xz) + Height(_DispTex1, _Cascade1, _Flow1, xz)
                     + Height(_DispTex2, _Cascade2, _Flow2, xz) + Height(_DispTex3, _Cascade3, _Flow3, xz);
            }

            // Dave Hoskins, "Hash without Sine" (MIT)
            float4 Hash42(float2 p)
            {
                float4 p4 = frac(float4(p.xyxy) * float4(0.1031, 0.1030, 0.0973, 0.1099));
                p4 += dot(p4, p4.wzxy + 33.33);
                return frac((p4.xxyz + p4.yzzw) * p4.zywx);
            }

            float4 frag (v2f_img i) : SV_Target
            {
                float2 res = _MainTex_TexelSize.zw;
                float S = res.y;
                float2 px = floor(i.uv * res);
                bool velHalf = px.x >= S;
                float2 cell = float2(px.x - (velHalf ? S : 0.0), px.y);
                if (_SprayParams.w > 0.5) return 0.0;

                float dt = max(_SprayParams.x, 1e-4);
                float V = _ShipSize.z;
                float2 aft = -_Ship.zw;
                float2 side = float2(-aft.y, aft.x);

                // Slamming: how fast the sea climbs each stem. The FFT may skip frames, so the
                // excess over the threshold is smoothed over ~0.15 s.
                float sp = saturate((V - 3.0) / 12.0);
                float slams[SHIP_COUNT], bowRates[SHIP_COUNT], slamRates[SHIP_COUNT];
                float total = 0.0;
                float4 state = 0.0;
                [unroll] for (int k = 0; k < SHIP_COUNT; k++)
                {
                    Ship sk = GetShip(k);
                    float4 g = tex2Dlod(_MainTex, float4((float2(k, 0.0) + 0.5) / res, 0, 0));
                    float hBow = WaterHeight(sk.bow);
                    float rise = g.w > 0.5 ? (hBow - g.x) / dt : 0.0;
                    slams[k] = lerp(g.y, max(rise - _SprayParams2.x, 0.0), 1.0 - exp(-dt / 0.15));
                    if (px.y == 0 && px.x == k) state = float4(hBow, slams[k], 0.0, 1e4);
                    bool on = sk.on > 0.5;
                    bowRates[k] = on ? 0.3 * sp * sp : 0.0;
                    slamRates[k] = on ? 25.0 * slams[k] : 0.0;
                    total += bowRates[k] + slamRates[k];
                }
                if (px.y == 0 && px.x < SHIP_COUNT) return state;

                float2 uvP = (cell + 0.5) / res;
                float4 p = tex2Dlod(_MainTex, float4(uvP, 0, 0));
                float4 v = tex2Dlod(_MainTex, float4(uvP + float2(0.5, 0.0), 0, 0));
                float seed = v.w;
                float life = lerp(1.2, 3.0, frac(seed * 7.13));
                // Drag relaxation time: fine mist follows the air in a fraction of a second, heavy
                // drops keep their throw.
                float tau = lerp(0.15, 2.0, frac(seed * 13.7) * frac(seed * 13.7));
                bool alive = seed > 0.0 && p.w < life;

                if (alive)
                {
                    float3 gtau = float3(0.0, -9.81, 0.0) * tau;
                    float3 u = _AirWind.xyz;
                    v.xyz = u + gtau + (v.xyz - u - gtau) * exp(-dt / tau);
                    p.xyz += v.xyz * dt;
                    p.w += dt;
                    // Back in the sea.
                    if (v.y < 0.0 && p.y < WaterHeight(p.xz) - 0.3) p.w = 1e4;
                }
                else
                {
                    // Dead: respawn with a probability set by the fleet's emission rate (the pool
                    // limits bursts), at a ship picked in proportion to its own rate.
                    float4 h = Hash42(cell * 1.37 + float2(fmod(_SprayParams.y, 4096.0) * 0.618, 17.0));
                    float q = saturate(dt * total * _SprayParams.z);
                    if (h.x < q)
                    {
                        float4 r = Hash42(h.yz * 913.7 + h.w * 71.3 + cell);
                        float u = h.y * total;
                        Ship sh = GetShip(0);
                        float slam = 0.0;
                        bool isSlam = false, picked = false;
                        [unroll] for (int k = 0; k < SHIP_COUNT; k++)
                        {
                            float rk = bowRates[k] + slamRates[k];
                            if (!picked && (u < rk || k == SHIP_COUNT - 1))
                            {
                                sh = GetShip(k);
                                slam = slams[k];
                                isSlam = u < slamRates[k];
                                picked = true;
                            }
                            else if (!picked) u -= rk;
                        }
                        float sgn = h.w < 0.5 ? -1.0 : 1.0;
                        float L = sh.L;
                        float a = isSlam ? 6.0 * r.x : 0.1 * L * r.x * r.x;   // m aft of the stem
                        float hw = 0.5 * sh.B * saturate(a / (0.2 * L));
                        float c = sgn * (hw + 0.5 + (isSlam ? 3.0 * r.y : 1.0 * r.y));
                        float2 xz = sh.bow + aft * a + side * c;
                        float y = WaterHeight(xz) + sh.hump * exp(-a * a / 225.0) + 0.3;
                        float3 vel;
                        if (isSlam)
                        {
                            float up = min(4.0 + 6.0 * sqrt(slam), 25.0) * (0.35 + 0.65 * r.z);
                            float outward = (1.5 + 2.0 * sqrt(slam)) * (0.3 + 0.7 * r.w);
                            vel = float3(0.0, up, 0.0) + float3(side.x, 0.0, side.y) * (sgn * outward)
                                + float3(aft.x, 0.0, aft.y) * (0.3 * V * r.x);
                        }
                        else
                        {
                            vel = float3(aft.x, 0.0, aft.y) * (V * (0.3 + 0.4 * r.z))
                                + float3(side.x, 0.0, side.y) * (sgn * V * (0.1 + 0.25 * r.w))
                                + float3(0.0, V * (0.15 + 0.5 * r.y * r.y), 0.0);
                        }
                        p = float4(xz.x, y, xz.y, 0.0);
                        v = float4(vel, max(Hash42(r.xy * 517.3 + r.zw).x, 1e-3));
                    }
                }
                return velHalf ? v : p;
            }
            ENDCG
        }
    }
}
