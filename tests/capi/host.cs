// C# host (ROADMAP 17.78): drives build/libludens.so only through the
// generated binding (bindings/csharp/Ludens.cs, from embed/ludens.h) and
// prints "key value" lines. The scenario is tests/capi/host.c's first one
// (and tests/capi/host.rs's): its world hash must equal the C host's.
// Build: a console project with AllowUnsafeBlocks that compiles this file
// and bindings/csharp/Ludens.cs; run with LD_LIBRARY_PATH=build.
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Ludens;
using static Ludens.Native;

static unsafe class Host
{
    static long player;
    static long preCalls;
    static readonly float[] VX = { 3f, 0f, -3f, 0f };
    static readonly float[] VZ = { 0f, 3f, 0f, -3f };

    // Moves the player around a square: 1 s per side at 3 m/s (host.c drive_player).
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    static int DrivePlayer(ld_world* w, double dt, long tick, void* user)
    {
        float* st = stackalloc float[13];
        if (ld_body_get_state(w, player, st) != LD_OK)
            return 1;
        int k = (int)((tick / 60) % 4);
        preCalls += 1;
        return ld_body_set_velocity(w, player, VX[k], st[8], VZ[k], 0f, 0f, 0f) == LD_OK ? 0 : 2;
    }

    static int Main()
    {
        Console.WriteLine("abi " + ld_abi_version());
        ld_world* w = null;
        if (ld_world_create(1.0 / 60.0, 0f, -9.8f, 0f, &w) != LD_OK)
        {
            Console.WriteLine("create failed");
            return 1;
        }
        ld_body_add_box(w, 0f, -0.5f, 0f, 20f, 0.5f, 20f, 0f, 1);
        for (int i = 0; i < 4; i++)
            for (int k = 0; k < 2; k++)
                ld_body_add_box(w, -3f + 2f * i, 0.25f + 0.51f * k, 2f, 0.25f, 0.25f, 0.25f, 1f, 0);
        for (int i = 0; i < 3; i++)
            ld_body_add_sphere(w, -2f + 2f * i, 1f + 0.5f * i, -2f, 0.3f, 0.5f, 0);
        player = ld_body_add_box(w, 0f, 0.4f, 0f, 0.4f, 0.4f, 0.4f, 2f, 0);
        ld_world_add_system(w, LD_PHASE_PRE, &DrivePlayer, null);
        for (int t = 0; t < 120; t++)
        {
            if (ld_world_step(w, 1.0 / 60.0) < 0)
            {
                Console.WriteLine("step failed");
                return 1;
            }
        }
        long ran = ld_world_step_ticks(w, 120);
        ulong h = 0;
        ld_world_hash(w, &h);
        Console.WriteLine("cs_ran " + ran);
        Console.WriteLine("cs_hash " + h.ToString("x16"));
        Console.WriteLine("cs_pre " + preCalls);
        Console.WriteLine("cs_stale " + ld_body_alive(w, player | (7L << 32)));
        Console.WriteLine("cs_destroy " + ld_world_destroy(w));
        return 0;
    }
}
