// The ships whose wakes are drawn (Ocean.shader, FoamSim.shader pass 0), set by OceanFFT cascade 0:
// the carrier and up to three escorts. The fleet steams together, so the escorts share the
// carrier's heading and speed (the water flows past all of them alike); only their hulls differ.
#ifndef VRCOCEAN_SHIPS
#define VRCOCEAN_SHIPS

float4 _Ship;        // (bow x, z, forward x, z)
float4 _ShipSize;    // (waterline length, beam, speed, draft)
float4 _Wake;        // (kelvin height, bow hump, foam, on)
float4 _Escort0, _Escort1, _Escort2;               // (bow x, z, waterline length, beam); length 0 = none
float4 _EscortWake0, _EscortWake1, _EscortWake2;   // (kelvin height, bow hump, foam, draft)

#define SHIP_COUNT 4

struct Ship
{
    float2 bow, aft;
    float L, B, V, T;
    float kelvin, hump, foam, on;
};

Ship GetShip(int i)
{
    Ship s;
    s.aft = -_Ship.zw;
    s.V = _ShipSize.z;
    if (i == 0)
    {
        s.bow = _Ship.xy; s.L = _ShipSize.x; s.B = _ShipSize.y; s.T = _ShipSize.w;
        s.kelvin = _Wake.x; s.hump = _Wake.y; s.foam = _Wake.z; s.on = _Wake.w;
        return s;
    }
    float4 e = i == 1 ? _Escort0 : i == 2 ? _Escort1 : _Escort2;
    float4 w = i == 1 ? _EscortWake0 : i == 2 ? _EscortWake1 : _EscortWake2;
    s.bow = e.xy; s.L = e.z; s.B = e.w; s.T = w.w;
    s.kelvin = w.x; s.hump = w.y; s.foam = w.z;
    s.on = (_Wake.w > 0.5 && e.z > 0.0) ? 1.0 : 0.0;
    return s;
}

#endif
