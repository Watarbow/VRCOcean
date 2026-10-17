using Tsukimi;
using UnityEngine;
using VRC.SDKBase;
using VRC.Udon;

// FFT ocean, one cascade. Port of GodotOceanWaves (MIT, Ethan Truong):
// TMA spectrum + Hasselmann spread -> time modulation -> 2D inverse FFT (Stockham, pixel kernels)
// -> displacement / normal+foam maps that Ocean.shader samples.
public partial class OceanFFT : TsukimiBehaviour
{
    [Header("Spectrum (needs Regenerate)")]
    public float tileLength = 88f;     // m, size of one tile
    public float windSpeed = 10f;      // m/s
    public float windDirection = 0f;   // degrees
    public float fetchKm = 150f;       // distance from shore
    public float depth = 20f;          // m
    public float swell = 0.8f;
    public float spread = 0.2f;
    public float detail = 1f;
    public int seed = 1234;
    // 1 = physical JONSWAP wave height. GodotOceanWaves' normalisation is ~2.83x this
    // (Var counted 8x: complex gaussian E|g|^2 = 2, sqrt(2 S) and the conj(h0(-k)) term).
    public float heightScale = 1f;

    [Header("Foam")]
    // Foam where the Jacobian drops below this. On cascade 0 it drives the foam sim: 0.65 gives
    // ~1.4% mean coverage at 10 m/s (Monahan & O'Muircheartaigh 1980: 3.84e-6 U^3.41 = 1.0%).
    public float whitecap = 0.5f;
    public float foamAmount = 8f;
    // Cascade 0 runs the persistent foam sim (Crest style): a world-space texture around the player
    // that keeps foam where the water parcel is while it fades, with no tile repetition.
    public Material foamSimMaterial;
    public float foamLifetime = 4f;    // s, e-folding time of residual foam
    public float foamSimSize = 512f;   // m, side of the simulated square (beyond it: the far sim)
    public int foamSimResolution = 1024;
    // Second, coarse sim out to kilometres (beyond it: per-tile foam).
    public float foamFarSize = 4096f;
    public int foamFarResolution = 512;
    public float foamFreshTime = 0.7f;   // s, how long foam reads as fresh (thick, bright)
    public float bubbleLifetime = 6f;    // s, subsurface bubble plume (lighter water under the foam)
    public float slickLifetime = 60f;    // s, surfactant left by decayed foam (smooth streaks)
    // Surface drift as a fraction of wind speed (wind drift + Stokes drift ~3%), plus any current.
    public float foamDrift = 0.03f;
    public Vector2 foamCurrent = Vector2.zero;   // m/s, world x / z
    // Langmuir rows: cross-wind convergence speed and row spacing that sweep slicks into streaks.
    public float langmuirSpeed = 0.1f;   // m/s
    public float langmuirSpacing = 30f;  // m

    [Header("Ship wake (cascade 0)")]
    // The ship stays put and the water flows past it at shipSpeed (players stay on a fixed deck and
    // aircraft land on a fixed hull). Every cascade's waves and the foam move with that water.
    public Transform ship;
    public float shipSpeed = 15f;        // m/s through the water, when there is no speedControl
    public ShipSpeed speedControl;       // the shared speed slider on the deck (optional)
    public Vector3 shipBow = new Vector3(0.77f, 16f, 258.8f);   // m from the ship's pivot along its axes: waterline stem
    public float shipLength = 479f;      // m, waterline
    public float shipBeam = 56f;         // m, waterline
    public float shipDraft = 15f;        // m; the hull radiates little at wavelengths shorter than this
    public float kelvinHeight = 1f;      // m, Kelvin wave amplitude one ship length astern
    public float bowHumpHeight = 1.5f;   // m, water piled up at the stem
    public float wakeFoam = 1f;          // foam per second churned up at the stern
    // Up to three escorts in company: same heading and speed as the ship (the water flows past all
    // of them alike), so only where they are and their hulls differ. One entry per escort in each array.
    public Transform[] escorts;
    public Vector3[] escortBow;          // m from each escort's pivot along its axes: waterline stem
    public Vector3[] escortHull;         // m, waterline length, beam, draft

    [Header("Spray (cascade 0)")]
    // GPU particles (FoamSim.shader pass 1, drawn by Spray.shader on the SprayQuads mesh): the bow
    // wave peeling off the stem, and slamming when the sea climbs the stem faster than slamThreshold.
    public Material sprayMaterial;
    public float sprayAmount = 1f;
    public float slamThreshold = 1f;     // m/s

    [Header("SaccFlight (cascade 0)")]
    // The air moves past the fixed ship as if the ship sailed through it: each vehicle's Wind is
    // -forward * speed plus the sea's own wind times seaWindOnAircraft (0 = the ship's motion only).
    public UdonBehaviour[] airVehicles;  // the SaccAirVehicle UdonBehaviours
    public float seaWindOnAircraft = 1f;

    [Header("Cascade")]
    // One OceanFFT per cascade, all on the clipmap object. Cascade 0 also moves the mesh.
    // Every cascade runs every frame: from the air only the far cascades are in view, and
    // skipping their frames reads as the whole sea dropping to a lower frame rate.
    public int cascadeIndex = 0;
    public float bandMin = 0f;          // rad/m, wavenumbers this cascade owns
    public float bandMax = 100000f;     // rad/m
    public float displacementScale = 1f;
    public float normalScale = 1f;

    [Header("Rendering")]
    public Material oceanMaterial;
    public float snapSize = 4f;        // coarsest clipmap_high ring spacing (0.25 / 1 / 4 m), so no ring swims
    // Flight: the clipmap doubles in size every time the altitude doubles past this,
    // and its outer ring is stretched out to skirtDistance (keep below the far clip).
    public float altitudePerScale = 60f;
    public float maxMeshScale = 64f;
    public float skirtDistance = 45000f;
    // Underwater.shader (cascade 0): finds the surface above the camera from the same waves.
    public Material underwaterMaterial;

    private const int N = 256;
    private const int Stages = 8;      // log2(N)
    private const float G = 9.81f;
    private const float Pi = 3.14159265f;
    // Frequencies are quantised to 2*pi/LoopPeriod so the clock can wrap
    // without a visible jump and the phase stays precise in float.
    private const float LoopPeriod = 400f;

    private GpuBuffer2D h0;
    // a | b side by side (2N x N): one pass transforms both, halving the FFT passes.
    private GpuBuffer2D ab0;
    private GpuBuffer2D ab1;
    private GpuBuffer2D disp;
    private GpuBuffer2D norm0;
    private GpuBuffer2D norm1;
    private RenderTexture dispRT;
    private RenderTexture normRT;
    private VRCPlayerApi local;
    private RenderTexture foamA;
    private RenderTexture foamB;
    private RenderTexture farA;
    private RenderTexture farB;
    private RenderTexture sprayA;
    private RenderTexture sprayB;
    private Vector2 foamCenter;
    private Vector2 farCenter;
    private bool foamReset = true;
    // Local clocks, accumulated in double so they stay smooth after hours. Not the server clock:
    // it jitters frame to frame, and that judder showed as a lower frame rate. Each player sees
    // their own waves and wake; sync them again if anything networked ever floats on the waves.
    private double waveTime;
    private double flowDistance;
    // Flow not yet applied to each foam sim: it moves in whole texels so the copy doesn't blur.
    private Vector2 nearFlow;
    private Vector2 farFlow;
    private string[] cascadeNames;
    private string[] flowNames;
    private string[] dispNames;
    private string[] escortNames;
    private string[] escortWakeNames;
    private Vector3 appliedWind = new Vector3(1e9f, 0f, 0f);

    void Start()
    {
        h0 = Gpu.Buffer(N, N, GpuFormat.Half);
        ab0 = Gpu.Buffer(2 * N, N, GpuFormat.Half);
        ab1 = Gpu.Buffer(2 * N, N, GpuFormat.Half);
        disp = Gpu.Buffer(N, N, GpuFormat.Half);
        norm0 = Gpu.Buffer(N, N, GpuFormat.Half);
        norm1 = Gpu.Buffer(N, N, GpuFormat.Half);

        // Gpu buffers are point-sampled and clamped; the shader needs repeat + mips.
        dispRT = MakeSampledRT();
        normRT = MakeSampledRT();
        if (oceanMaterial != null)
        {
            oceanMaterial.SetTexture("_DispTex" + cascadeIndex, dispRT);
            oceanMaterial.SetTexture("_NormTex" + cascadeIndex, normRT);
        }
        // The skirt is pushed out in the vertex shader; widen the bounds so the ocean
        // isn't frustum-culled when looking at the horizon from altitude.
        MeshRenderer mr = GetComponentInChildren<MeshRenderer>();
        if (mr != null && cascadeIndex == 0) mr.localBounds = new Bounds(Vector3.zero, new Vector3(2f * skirtDistance, 40f, 2f * skirtDistance));
        if (foamSimMaterial != null) foamSimMaterial.SetTexture("_DispTex" + cascadeIndex, dispRT);
        if (cascadeIndex == 0 && foamSimMaterial != null && oceanMaterial != null)
        {
            foamA = MakeFoamRT(foamSimResolution);
            foamB = MakeFoamRT(foamSimResolution);
            farA = MakeFoamRT(foamFarResolution);
            farB = MakeFoamRT(foamFarResolution);
            if (sprayMaterial != null)
            {
                sprayA = MakeSprayRT();
                sprayB = MakeSprayRT();
            }
        }
        local = Networking.LocalPlayer;
        cascadeNames = new string[] { "_Cascade0", "_Cascade1", "_Cascade2", "_Cascade3" };
        flowNames = new string[] { "_Flow0", "_Flow1", "_Flow2", "_Flow3" };
        dispNames = new string[] { "_DispTex0", "_DispTex1", "_DispTex2", "_DispTex3" };
        escortNames = new string[] { "_Escort0", "_Escort1", "_Escort2" };
        escortWakeNames = new string[] { "_EscortWake0", "_EscortWake1", "_EscortWake2" };
        Regenerate();
    }

    private RenderTexture MakeSampledRT()
    {
        RenderTexture rt = new RenderTexture(N, N, 0, RenderTextureFormat.ARGBHalf, RenderTextureReadWrite.Linear);
        rt.useMipMap = true;
        rt.autoGenerateMips = true;
        rt.wrapMode = TextureWrapMode.Repeat;
        rt.filterMode = FilterMode.Trilinear;
        rt.anisoLevel = 8;
        rt.Create();
        return rt;
    }

    private RenderTexture MakeFoamRT(int res)
    {
        RenderTexture rt = new RenderTexture(res, res, 0, RenderTextureFormat.ARGBHalf, RenderTextureReadWrite.Linear);
        rt.useMipMap = true;
        rt.autoGenerateMips = true;
        rt.wrapMode = TextureWrapMode.Clamp;
        rt.filterMode = FilterMode.Trilinear;
        rt.Create();
        return rt;
    }

    // 64 x 64 particles: position | velocity side by side, point-sampled floats.
    private RenderTexture MakeSprayRT()
    {
        RenderTexture rt = new RenderTexture(128, 64, 0, RenderTextureFormat.ARGBFloat, RenderTextureReadWrite.Linear);
        rt.wrapMode = TextureWrapMode.Clamp;
        rt.filterMode = FilterMode.Point;
        rt.Create();
        return rt;
    }

    // Call after changing anything under "Spectrum".
    public void Regenerate()
    {
        float fetch = fetchKm * 1000f;
        Gpu.Run(nameof(InitSpectrum), h0,
            new Vector4(tileLength, JonswapAlpha(windSpeed, fetch), JonswapPeakOmega(windSpeed, fetch), windSpeed),
            new Vector4(windDirection * Mathf.Deg2Rad, depth, swell, detail),
            heightScale,
            new Vector4(spread, seed, bandMin, bandMax));
        if (oceanMaterial != null)
            oceanMaterial.SetVector("_Cascade" + cascadeIndex, new Vector4(tileLength, displacementScale, normalScale, 0f));
        if (foamSimMaterial != null)
            foamSimMaterial.SetVector("_Cascade" + cascadeIndex, new Vector4(tileLength, displacementScale, normalScale, 0f));
    }

    void Update()
    {
        if (cascadeIndex == 0)
        {
            FollowPlayer();
            SetShip();
        }

        waveTime = (waveTime + Time.deltaTime) % LoopPeriod;
        float t = (float)waveTime;
        Vector4 mp = new Vector4(tileLength, depth, t, 2f * Pi / LoopPeriod);
        Gpu.Run(nameof(Modulate), ab0, h0, mp);

        for (int s = 0; s < Stages; s++)
        {
            Gpu.Run(nameof(FftX), ab1, ab0, 1 << s);
            Gpu.Swap(ref ab0, ref ab1);
        }
        for (int s = 0; s < Stages; s++)
        {
            Gpu.Run(nameof(FftY), ab1, ab0, 1 << s);
            Gpu.Swap(ref ab0, ref ab1);
        }

        float dt = Time.deltaTime;
        Vector4 fp = new Vector4(whitecap, dt * foamAmount * 7.5f, dt * Mathf.Max(0.5f, 10f - foamAmount) * 1.15f, 0f);
        Gpu.Run(nameof(UnpackDisp), disp, ab0);
        Gpu.Run(nameof(UnpackNormal), norm1, ab0, norm0, fp);
        Gpu.Swap(ref norm0, ref norm1);

        VRCGraphics.Blit(Gpu.Texture(disp), dispRT);
        VRCGraphics.Blit(Gpu.Texture(norm0), normRT);
    }

    // Runs after every cascade's Update so the sim sees this frame's Jacobians.
    void LateUpdate()
    {
        if (foamA == null || local == null) return;
        Vector3 head = local.GetTrackingData(VRCPlayerApi.TrackingDataType.Head).position;
        float dt = Time.deltaTime;
        float a = windDirection * Mathf.Deg2Rad;
        // The spectrum's k points into the wind (waves travel along -k), so downwind is -(sin, cos).
        Vector2 down = new Vector2(-Mathf.Sin(a), -Mathf.Cos(a));
        Vector2 drift = down * (foamDrift * windSpeed) + foamCurrent;
        foamSimMaterial.SetVector("_FoamParams", new Vector4(whitecap, dt * foamAmount * 7.5f,
            Mathf.Exp(-dt / Mathf.Max(foamLifetime, 0.05f)), foamReset ? 1f : 0f));
        foamSimMaterial.SetVector("_Decay", new Vector4(Mathf.Exp(-dt / Mathf.Max(foamFreshTime, 0.05f)),
            Mathf.Exp(-dt / Mathf.Max(bubbleLifetime, 0.05f)), Mathf.Exp(-dt / Mathf.Max(slickLifetime, 0.05f)), 0f));
        foamSimMaterial.SetVector("_Advect", new Vector4(drift.x, drift.y, down.x, down.y));
        foamSimMaterial.SetVector("_Langmuir", new Vector4(langmuirSpeed, langmuirSpacing, 0f, 0f));
        bool reset = foamReset;
        foamReset = false;
        float nearTexel = foamSimSize / foamSimResolution;
        float farTexel = foamFarSize / foamFarResolution;
        Vector2 flow = FlowVelocity() * dt;
        nearFlow += flow;
        Vector2 nearStep = SnapToGrid(nearFlow, nearTexel);
        nearFlow -= nearStep;
        farFlow += flow;
        Vector2 farStep = SnapToGrid(farFlow, farTexel);
        farFlow -= farStep;

        foamCenter = StepFoam(foamA, foamB, foamCenter, nearStep, nearFlow, foamSimSize, foamSimResolution, nearTexel, head, dt);
        RenderTexture t = foamA;
        foamA = foamB;
        foamB = t;
        farCenter = StepFoam(farA, farB, farCenter, farStep, farFlow, foamFarSize, foamFarResolution, nearTexel, head, dt);
        t = farA;
        farA = farB;
        farB = t;
        if (sprayA != null)
        {
            foamSimMaterial.SetVector("_SprayParams", new Vector4(dt, Time.frameCount % 4096, sprayAmount, reset ? 1f : 0f));
            foamSimMaterial.SetVector("_SprayParams2", new Vector4(slamThreshold, 0f, 0f, 0f));
            VRCGraphics.Blit(sprayA, sprayB, foamSimMaterial, 1);
            t = sprayA;
            sprayA = sprayB;
            sprayB = t;
            sprayMaterial.SetTexture("_SprayState", sprayA);
        }

        oceanMaterial.SetTexture("_FoamSim", foamA);
        // The texture lags the water by the sub-texel flow not yet applied; sampling shifted by it
        // makes the foam glide instead of jumping a texel at a time (8 m on the far sim).
        oceanMaterial.SetVector("_FoamSimArea", new Vector4(foamCenter.x + nearFlow.x, foamCenter.y + nearFlow.y, foamSimSize, 1f));
        oceanMaterial.SetTexture("_FoamSimFar", farA);
        oceanMaterial.SetVector("_FoamSimFarArea", new Vector4(farCenter.x + farFlow.x, farCenter.y + farFlow.y, foamFarSize, 1f));
        oceanMaterial.SetVector("_WindDown", new Vector4(down.x, down.y, 0f, 0f));
    }

    // One sim step from src into dst, the water having moved flowStep (whole texels) with flowRest
    // still to go; returns the new centre.
    private Vector2 StepFoam(RenderTexture src, RenderTexture dst, Vector2 prevCenter, Vector2 flowStep, Vector2 flowRest, float size, int res,
                             float jacTexel, Vector3 head, float dt)
    {
        // Snap to whole texels: the texture then follows the player and the flow without
        // resampling; only the drift (sub-texel per frame) is interpolated.
        float texel = size / res;
        Vector2 c = SnapToGrid(new Vector2(head.x, head.z), texel);
        Vector2 shift = (c - prevCenter - flowStep) / size;
        // Each texel holds the water that is really flowRest further on: whitecaps and the wake are
        // evaluated there, so they stay put relative to the waves and the ship.
        foamSimMaterial.SetVector("_Sim", new Vector4(c.x + flowRest.x, c.y + flowRest.y, size, texel));
        foamSimMaterial.SetVector("_Shift", new Vector4(shift.x, shift.y, jacTexel, dt));
        // Pass 0 only: without a pass index Blit draws every pass (pass 1 is the spray).
        VRCGraphics.Blit(src, dst, foamSimMaterial, 0);
        return c;
    }

    private static Vector2 SnapToGrid(Vector2 v, float grid)
    {
        return new Vector2(Mathf.Round(v.x / grid) * grid, Mathf.Round(v.y / grid) * grid);
    }

    // Cascade 0: the ship's waterline and speed for the wake (Ocean.shader, FoamSim.shader).
    private void SetShip()
    {
        if (oceanMaterial == null) return;
        bool on = ship != null;
        Vector3 bow = on ? ship.position + ship.rotation * shipBow : Vector3.zero;   // m, the ship's scale ignored
        Vector3 f = on ? ship.forward : Vector3.forward;
        Vector2 fwd = new Vector2(f.x, f.z).normalized;
        Vector4 s = new Vector4(bow.x, bow.z, fwd.x, fwd.y);
        // The speed ramp stays on the server clock (shared, and too slow to judder).
        float speed = !on ? 0f : speedControl != null ? speedControl.SpeedAt(Networking.GetServerTimeInSeconds()) : shipSpeed;
        flowDistance += speed * Time.deltaTime;
        double dist = flowDistance;
        Vector4 size = new Vector4(shipLength, shipBeam, speed, shipDraft);
        Vector4 w = new Vector4(kelvinHeight, bowHumpHeight, wakeFoam, on ? 1f : 0f);
        oceanMaterial.SetVector("_Ship", s);
        oceanMaterial.SetVector("_ShipSize", size);
        oceanMaterial.SetVector("_Wake", w);
        // The far trail's closed form decays like the foam sim (Ocean.shader WakeTrail).
        oceanMaterial.SetVector("_WakeTrail", new Vector4(foamLifetime, foamFreshTime, bubbleLifetime, slickLifetime));
        SetEscorts();
        SetFlow(-fwd, dist);
        // The air past the fixed ship: the ship's motion plus the sea's own wind.
        float a = windDirection * Mathf.Deg2Rad;
        Vector3 air = new Vector3(-fwd.x * speed - Mathf.Sin(a) * windSpeed, 0f, -fwd.y * speed - Mathf.Cos(a) * windSpeed);
        SetAirWind(-fwd, speed);
        if (foamSimMaterial == null) return;
        foamSimMaterial.SetVector("_AirWind", air);
        foamSimMaterial.SetVector("_Ship", s);
        foamSimMaterial.SetVector("_ShipSize", size);
        foamSimMaterial.SetVector("_Wake", w);
    }

    // Ocean.shader / FoamSim.shader (Ships.cginc): each escort's bow and hull; the heading, speed
    // and on/off come from the ship's. Waterline length 0 switches an escort off.
    private void SetEscorts()
    {
        for (int i = 0; i < 3; i++)
        {
            Vector4 e = Vector4.zero;
            Vector4 w = Vector4.zero;
            Transform t = escorts != null && i < escorts.Length ? escorts[i] : null;
            if (t != null && escortBow != null && i < escortBow.Length && escortHull != null && i < escortHull.Length)
            {
                Vector3 bow = t.position + t.rotation * escortBow[i];
                Vector3 hull = escortHull[i];
                // ponytail: Kelvin waves and bow hump scaled by beam only; give escorts their own heights if a class looks off.
                float r = hull.y / Mathf.Max(shipBeam, 1f);
                e = new Vector4(bow.x, bow.z, hull.x, hull.y);
                w = new Vector4(kelvinHeight * r, bowHumpHeight * r, wakeFoam, hull.z);
            }
            oceanMaterial.SetVector(escortNames[i], e);
            oceanMaterial.SetVector(escortWakeNames[i], w);
            if (foamSimMaterial == null) continue;
            foamSimMaterial.SetVector(escortNames[i], e);
            foamSimMaterial.SetVector(escortWakeNames[i], w);
        }
    }

    // m/s of the water past the fixed ship (aft); read back from what cascade 0 set.
    private Vector2 FlowVelocity()
    {
        if (oceanMaterial == null) return Vector2.zero;
        Vector4 s = oceanMaterial.GetVector("_Ship");
        float v = oceanMaterial.GetVector("_ShipSize").z;
        return new Vector2(-s.z * v, -s.w * v);
    }

    // The waves ride on the flowing water: offset every cascade's tile by the distance the water
    // has flowed (flowDistance), wrapped in double so it stays
    // exact after hours. Tile lengths come from what each cascade put on the material.
    private void SetFlow(Vector2 aft, double dist)
    {
        for (int i = 0; i < 4; i++)
        {
            float tile = oceanMaterial.GetVector(cascadeNames[i]).x;
            if (tile < 1f) continue;   // that cascade hasn't started yet
            Vector4 f = new Vector4(Wrap(aft.x * dist / tile), Wrap(aft.y * dist / tile), 0f, 0f);
            oceanMaterial.SetVector(flowNames[i], f);
            if (foamSimMaterial != null) foamSimMaterial.SetVector(flowNames[i], f);
            if (underwaterMaterial != null)
            {
                underwaterMaterial.SetVector(flowNames[i], f);
                underwaterMaterial.SetVector(cascadeNames[i], oceanMaterial.GetVector(cascadeNames[i]));
                underwaterMaterial.SetTexture(dispNames[i], oceanMaterial.GetTexture(dispNames[i]));
            }
        }
        if (underwaterMaterial != null)
        {
            underwaterMaterial.SetFloat("_DispScale", oceanMaterial.GetFloat("_DispScale"));
            underwaterMaterial.SetFloat("_Chlorophyll", oceanMaterial.GetFloat("_Chlorophyll"));
            underwaterMaterial.SetFloat("_UnderwaterExposure", oceanMaterial.GetFloat("_UnderwaterExposure"));
        }
        // Foam lace: its hash repeats every 4096 cells of the coarse octave.
        // ponytail: the finer octaves don't repeat there, so they jump once per wrap (~5.5 min at 15 m/s).
        float lace = 4096f * oceanMaterial.GetFloat("_FoamCell");
        oceanMaterial.SetVector("_FoamLaceOffset", new Vector4(Wrap(aft.x * dist / lace) * lace, Wrap(aft.y * dist / lace) * lace, 0f, 0f));
    }

    // SaccFlight computes airspeed as velocity - Wind, so a wind blowing aft at the ship's speed makes
    // the fixed carrier fly like a moving one (wind over the deck, slower closing speed on approach).
    private void SetAirWind(Vector2 aft, float speed)
    {
        if (airVehicles == null) return;
        float a = windDirection * Mathf.Deg2Rad;
        float sea = windSpeed * seaWindOnAircraft;
        Vector3 wind = new Vector3(aft.x * speed - Mathf.Sin(a) * sea, 0f, aft.y * speed - Mathf.Cos(a) * sea);
        if ((wind - appliedWind).sqrMagnitude < 1e-4f) return;
        appliedWind = wind;
        for (int i = 0; i < airVehicles.Length; i++)
            if (airVehicles[i] != null) airVehicles[i].SetProgramVariable("Wind", wind);
    }

    private static float Wrap(double x)
    {
        return (float)(x - System.Math.Floor(x));
    }

    // The mesh follows the player in whole grid steps; the shader samples by world XZ.
    private void FollowPlayer()
    {
        if (local == null) return;
        Vector3 head = local.GetTrackingData(VRCPlayerApi.TrackingDataType.Head).position;
        Vector3 p = transform.position;
        float scale = MeshScaleForAltitude(Mathf.Abs(head.y - p.y), altitudePerScale, maxMeshScale);
        float snap = snapSize * scale;     // keep vertices on the scaled grid so they don't swim
        transform.position = new Vector3(Mathf.Ceil(head.x / snap) * snap, p.y, Mathf.Ceil(head.z / snap) * snap);
        transform.localScale = new Vector3(scale, 1f, scale);
        if (oceanMaterial != null)
        {
            oceanMaterial.SetFloat("_MeshScale", scale);
            oceanMaterial.SetFloat("_SkirtDistance", skirtDistance);
        }
    }

    // Power of two so the snap grid of one scale contains the grids of the smaller ones.
    private static float MeshScaleForAltitude(float altitude, float perScale, float maxScale)
    {
        float scale = 1f;
        while (scale < maxScale && altitude > perScale * scale) scale *= 2f;
        return scale;
    }

    // --- Udon-side helpers (https://wikiwaves.org/Ocean-Wave_Spectra#JONSWAP_Spectrum) ---

    private static float JonswapAlpha(float wind, float fetch)
    {
        return 0.076f * Mathf.Pow(wind * wind / (fetch * G), 0.22f);
    }

    private static float JonswapPeakOmega(float wind, float fetch)
    {
        return 22f * Mathf.Pow(G * G / (wind * fetch), 1f / 3f);
    }

    // --- Shared math (kernel + tests) ---

    // Radix-2 Stockham, gather form: output j of the stage with half-size `span`
    // reads x[src] and x[src + n/2] and takes the + branch when lower.
    // span and n are powers of two, so bit ops replace the signed int / and % (slow on GPUs).
    private static int FftSource(int j, int span)
    {
        return ((j & ~(2 * span - 1)) >> 1) + (j & (span - 1));
    }

    // Packed a | b buffer: x in [0, 2n) reads from its own half.
    private static int FftPackedSource(int x, int n, int span)
    {
        int lx = x & (n - 1);
        return FftSource(lx, span) + (x - lx);
    }

    private static bool FftIsLower(int j, int span)
    {
        return (j & span) == 0;
    }

    private static float Tanh(float x)
    {
        x = Mathf.Clamp(x, -9f, 9f);
        float e = Mathf.Exp(2f * x);
        return (e - 1f) / (e + 1f);
    }

    private static float Omega(float k, float depth)
    {
        return Mathf.Sqrt(G * k * Tanh(k * depth));
    }

    // Horvath 2015: JONSWAP with Kitaigorodskii depth attenuation.
    private static float Tma(float w, float wp, float alpha, float depth)
    {
        float sigma = w <= wp ? 0.07f : 0.09f;
        float r = Mathf.Exp(-(w - wp) * (w - wp) / (2f * sigma * sigma * wp * wp));
        float jonswap = alpha * G * G / Mathf.Pow(w, 5f) * Mathf.Exp(-1.25f * Mathf.Pow(wp / w, 4f)) * Mathf.Pow(3.3f, r);
        float wh = Mathf.Min(w * Mathf.Sqrt(depth / G), 2f);
        float atten = wh <= 1f ? 0.5f * wh * wh : 1f - 0.5f * (2f - wh) * (2f - wh);
        return jonswap * atten;
    }

    private static float HasselmannSpread(float w, float wp, float wind, float theta, float swell)
    {
        float p = w / wp;
        float s = w <= wp
            ? 6.97f * Mathf.Pow(p, 4.06f)
            : 9.77f * Mathf.Pow(p, -2.33f - 1.45f * (wind * wp / G - 1.17f));
        s += 16f * Tanh(wp / w) * swell * swell;
        float a = Mathf.Sqrt(s);
        float norm = s < 0.4f
            ? 0.5f / Pi + s * (0.220636f + s * (-0.109f + s * 0.090f))
            : (a * 0.5f + 0.0625f / a) / Mathf.Sqrt(Pi);
        return norm * Mathf.Pow(Mathf.Abs(Mathf.Cos(theta * 0.5f)), 2f * s);
    }

    private static Vector2 CMul(Vector2 a, Vector2 b)
    {
        return new Vector2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
    }

    // --- GPU side ---

    // h0(k) for cell (x, y): complex gaussian * sqrt(2 S(w) D(w, theta) dw/dk / k dk^2).
    // Takes a KernelId so it stays on the GPU side (Gpu.Hash is GPU-only).
    private static Vector2 Amplitude(KernelId c, int n, Vector4 p0, Vector4 p1, Vector4 p2)
    {
        int x = c.X;
        int y = c.Y;
        int h2 = n >> 1;
        if (x == h2 && y == h2) return Vector2.zero;
        float dk = 2f * Pi / p0.x;
        Vector2 kv = new Vector2((x - h2) * dk, (y - h2) * dk);
        float k = kv.magnitude;
        if (k < p2.z || k >= p2.w) return Vector2.zero;   // another cascade owns this band
        float theta = Mathf.Atan2(kv.x, kv.y);

        float kd = k * p1.y;
        float th = Tanh(kd);
        float w = Mathf.Sqrt(G * k * th);
        float dwdk = 0.5f * G * (th + kd * (1f - th * th)) / w;
        float s = Tma(w, p0.z, p0.y, p1.y);
        float d = Mathf.Lerp(0.5f / Pi, HasselmannSpread(w, p0.z, p0.w, theta - p1.x, p1.z), 1f - p2.x)
                  * Mathf.Exp(-(1f - p1.w) * (1f - p1.w) * k * k);

        int h = Gpu.Hash(Gpu.Hash(x, y) + (int)p2.y);
        float u1 = Mathf.Max(Gpu.Random01(h), 1e-6f);
        float u2 = Gpu.Random01(Gpu.Hash(h + 1));
        float r = Mathf.Sqrt(-2f * Mathf.Log(u1));
        // E|h0|^2 = S(k) dk^2 / 2 so that Var(height) = integral of S; E|gauss|^2 = 2.
        float g = 0.5f * Mathf.Sqrt(s * d * dwdk / k * dk * dk);
        return new Vector2(r * Mathf.Cos(2f * Pi * u2), r * Mathf.Sin(2f * Pi * u2)) * g;
    }

    // p0 = (tileLength, alpha, peakOmega, windSpeed), p1 = (angle, depth, swell, detail), p2 = (spread, seed, bandMin, bandMax)
    // RG = h0(k), BA = conj(h0(-k))
    [Kernel]
    static Color4 InitSpectrum(KernelId id, Vector4 p0, Vector4 p1, float heightScale, Vector4 p2)
    {
        int n = Gpu.OutWidth;
        Vector2 a = Amplitude(id, n, p0, p1, p2) * heightScale;
        Vector2 b = Amplitude(new KernelId((n - id.X) & (n - 1), (n - id.Y) & (n - 1)), n, p0, p1, p2) * heightScale;
        return new Color4(a.x, a.y, b.x, -b.y);
    }

    // n is passed in: Gpu.OutWidth inside a helper generates a shader that does not compile.
    private static Vector2 KVec(KernelId id, int n, float tile)
    {
        float dk = 2f * Pi / tile;
        return new Vector2((id.X - (n >> 1)) * dk, (id.Y - (n >> 1)) * dk);
    }

    // h(k, t) = h0(k) e^{iwt} + conj(h0(-k)) e^{-iwt}; mp = (tileLength, depth, time, omegaStep)
    private static Vector2 Evolve(Color4 c, float k, Vector4 mp)
    {
        float w = Mathf.Floor(Omega(k, mp.y) / mp.w) * mp.w;
        float ph = w * mp.z;
        Vector2 m = new Vector2(Mathf.Cos(ph), Mathf.Sin(ph));
        return CMul(new Vector2(c.R, c.G), m) + CMul(new Vector2(c.B, c.A), new Vector2(m.x, -m.y));
    }

    // Two real fields per complex channel (their IFFTs land in re / im).
    // Left half (a): RG = Dx + i*h, BA = Dz + i*dh/dx. Right half (b): see ModulateB.
    [Kernel]
    static Color4 Modulate(KernelId id, GpuBuffer2D spec, Vector4 mp)
    {
        int n = Gpu.OutHeight;
        KernelId kid = new KernelId(id.X & (n - 1), id.Y);
        Vector2 kv = KVec(kid, n, mp.x);
        float k = kv.magnitude + 1e-6f;
        Vector2 h = Evolve(spec[kid], k, mp);
        return id.X < n ? ModulateA(kv, k, h) : ModulateB(kv, k, h);
    }

    private static Color4 ModulateA(Vector2 kv, float k, Vector2 h)
    {
        Vector2 hi = new Vector2(-h.y, h.x);         // i*h
        Vector2 hx = hi * (kv.x / k);                // choppy: +i k/|k| h (crests sharpen)
        Vector2 hz = hi * (kv.y / k);
        Vector2 dhdx = hi * kv.x;
        return new Color4(hx.x - h.y, hx.y + h.x, hz.x - dhdx.y, hz.y + dhdx.x);
    }

    // RG = dh/dz + i*dDx/dx, BA = dDz/dz + i*dDz/dx
    private static Color4 ModulateB(Vector2 kv, float k, Vector2 h)
    {
        Vector2 hi = new Vector2(-h.y, h.x);
        Vector2 dhdz = hi * kv.y;
        Vector2 dxdx = h * (-kv.x * kv.x / k);
        Vector2 dzdz = h * (-kv.y * kv.y / k);
        Vector2 dzdx = h * (-kv.x * kv.y / k);
        return new Color4(dhdz.x - dxdx.y, dhdz.y + dxdx.x, dzdz.x - dzdx.y, dzdz.y + dzdx.x);
    }

    private static Color4 Butterfly(Color4 x0, Color4 x1, int j, int span)
    {
        float ang = Pi * (j & (span - 1)) / span;     // inverse transform: +2*pi*i*k/(2*span)
        Vector2 w = new Vector2(Mathf.Cos(ang), Mathf.Sin(ang));
        Vector2 p = CMul(new Vector2(x1.R, x1.G), w);
        Vector2 q = CMul(new Vector2(x1.B, x1.A), w);
        float sg = FftIsLower(j, span) ? 1f : -1f;
        return new Color4(x0.R + sg * p.x, x0.G + sg * p.y, x0.B + sg * q.x, x0.A + sg * q.y);
    }

    [Kernel]
    static Color4 FftX(KernelId id, GpuBuffer2D src, int span)
    {
        // Each half is its own transform of width n.
        int n = Gpu.OutHeight;
        int i = FftPackedSource(id.X, n, span);
        return Butterfly(src[new KernelId(i, id.Y)], src[new KernelId(i + (n >> 1), id.Y)], id.X & (n - 1), span);
    }

    [Kernel]
    static Color4 FftY(KernelId id, GpuBuffer2D src, int span)
    {
        int i = FftSource(id.Y, span);
        return Butterfly(src[new KernelId(id.X, i)], src[new KernelId(id.X, i + (Gpu.OutHeight >> 1))], id.Y, span);
    }

    // The spectrum is centred, so the IFFT output carries (-1)^(x+y).
    private static float ShiftSign(KernelId id)
    {
        return ((id.X + id.Y) & 1) == 0 ? 1f : -1f;
    }

    // RGB = displacement (x, height, z), A = Jacobian - 1 (summed over cascades by the foam sim)
    [Kernel]
    static Color4 UnpackDisp(KernelId id, GpuBuffer2D ab)
    {
        float s = ShiftSign(id);
        Color4 c = ab[id];
        Color4 cb = ab[new KernelId(id.X + Gpu.OutWidth, id.Y)];
        return new Color4(c.R * s, c.G * s, c.B * s, Jacobian(cb.G * s, cb.B * s, cb.A * s) - 1f);
    }

    private static float Jacobian(float dxdx, float dzdz, float dzdx)
    {
        return (1f + dxdx) * (1f + dzdz) - dzdx * dzdx;
    }

    // R,G = height gradient (x, z), B = mean squared slope per axis (LEADR: mips of B minus the
    // square of the mipped R,G give the slope variance lost to filtering), A = foam.
    // fp = (whitecap, grow, decay, -)
    [Kernel]
    static Color4 UnpackNormal(KernelId id, GpuBuffer2D ab, GpuBuffer2D prev, Vector4 fp)
    {
        float s = ShiftSign(id);
        Color4 ca = ab[id];
        Color4 cb = ab[new KernelId(id.X + Gpu.OutWidth, id.Y)];
        float dhdx = ca.A * s;
        float dhdz = cb.R * s;
        float dxdx = cb.G * s;
        float dzdz = cb.B * s;
        float dzdx = cb.A * s;
        float jac = Jacobian(dxdx, dzdz, dzdx);
        float foam = prev[id].A * Mathf.Exp(-fp.z) + Mathf.Max(0f, fp.x - jac) * fp.y;
        float gx = dhdx / (1f + Mathf.Abs(dxdx));
        float gz = dhdz / (1f + Mathf.Abs(dzdz));
        return new Color4(gx, gz, 0.5f * (gx * gx + gz * gz), Mathf.Clamp01(foam));
    }
}
