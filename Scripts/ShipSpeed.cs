using Tsukimi;
using UnityEngine;
using UnityEngine.UI;
using VRC.SDKBase;

// Ship speed through the water, shared by everyone. A slider on the deck sets the target and the
// ship eases to it at `acceleration`, so the wake and the aircraft's airspeed never jump.
// Only the start of the current ramp is synced; every client (and a late joiner) computes the
// speed and the distance the water has flowed from it and the server clock, so all agree.
[UdonBehaviourSyncMode(BehaviourSyncMode.Manual)]
public partial class ShipSpeed : TsukimiBehaviour
{
    public Slider slider;
    public Text label;
    public float acceleration = 0.3f;    // m/s^2 (0 -> 15 m/s in 50 s)
    public float initialSpeed = 15f;     // m/s

    // The ramp in progress: at server time rampStartTime the water had flowed rampStartDistance
    // and the ship was doing rampFrom; it reaches rampTo after |rampTo - rampFrom| / acceleration.
    // The defaults (0, 0) make every client start from the same state without any sync.
    [UdonSynced] public double rampStartTime;
    [UdonSynced] public double rampStartDistance;
    [UdonSynced] public float rampFrom;
    [UdonSynced] public float rampTo;

    private bool started;
    private float shown = -1f;

    void Start()
    {
        if (!started)   // OnDeserialization may already have landed
        {
            rampFrom = initialSpeed;
            rampTo = initialSpeed;
        }
        started = true;
        Show();
    }

    public float SpeedAt(double t)
    {
        return SpeedOnRamp(rampFrom, rampTo, acceleration, t - rampStartTime);
    }

    // m along the ship's aft direction the water has flowed by server time t.
    public double DistanceAt(double t)
    {
        return rampStartDistance + DistanceOnRamp(rampFrom, rampTo, acceleration, t - rampStartTime);
    }

    // Slider -> On Value Changed -> UdonBehaviour.SendCustomEvent("OnSliderChanged").
    public void OnSliderChanged()
    {
        if (slider == null) return;
        float v = slider.value;
        if (Mathf.Abs(v - rampTo) < 0.01f) return;
        SetTarget(v, Networking.GetServerTimeInSeconds());
    }

    public void SetTarget(float speed, double now)
    {
        if (!Networking.IsOwner(gameObject)) Networking.SetOwner(Networking.LocalPlayer, gameObject);
        // Start the new ramp from where the old one is now, so speed and distance stay continuous.
        double d = DistanceAt(now);
        float s = SpeedAt(now);
        rampStartTime = now;
        rampStartDistance = d;
        rampFrom = s;
        rampTo = speed;
        started = true;
        RequestSerialization();
        Show();
    }

    public override void OnDeserialization()
    {
        started = true;
        Show();
    }

    void Update()
    {
        // Only while the ship is still changing speed (the label shows it), not every frame.
        if (shown != rampTo || SpeedAt(Networking.GetServerTimeInSeconds()) != rampTo) Show();
    }

    private void Show()
    {
        float now = SpeedAt(Networking.GetServerTimeInSeconds());
        shown = now == rampTo ? rampTo : -1f;
        if (slider != null) slider.SetValueWithoutNotify(rampTo);
        if (label == null) return;
        string s = "Ship speed  " + now.ToString("F1") + " m/s  (" + (now * 1.943844f).ToString("F0") + " kn)";
        if (now != rampTo) s += "  -> " + rampTo.ToString("F1");
        label.text = s;
    }

    private static float SpeedOnRamp(float from, float to, float accel, double tau)
    {
        float dv = to - from;
        double ramp = Mathf.Abs(dv) / Mathf.Max(accel, 1e-3f);
        if (tau >= ramp) return to;
        if (tau <= 0.0) return from;
        return from + (dv > 0f ? 1f : -1f) * Mathf.Max(accel, 1e-3f) * (float)tau;
    }

    private static double DistanceOnRamp(float from, float to, float accel, double tau)
    {
        float dv = to - from;
        float a = Mathf.Max(accel, 1e-3f);
        double ramp = Mathf.Abs(dv) / a;
        double r = tau < ramp ? tau : ramp;
        if (r < 0.0) r = 0.0;
        double d = from * r + 0.5 * (dv > 0f ? a : -a) * r * r;
        return d + to * (tau - r);
    }
}
