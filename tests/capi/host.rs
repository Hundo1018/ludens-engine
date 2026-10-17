// Rust host for tests/test_capi.mojo (ROADMAP 17.78): drives
// build/libludens.so only through the generated bindings
// (bindings/rust/ludens_sys.rs, from embed/ludens.h) and prints "key value"
// lines. The scenario is tests/capi/host.c's first one: the test checks the
// world hash equals the C host's.
#[path = "../../bindings/rust/ludens_sys.rs"]
mod ludens_sys;

use core::ffi::c_void;
use ludens_sys::*;

struct HostState {
    player: ld_body,
    pre_calls: i64,
}

// Moves the player around a square: 1 s per side at 3 m/s (host.c drive_player).
unsafe extern "C" fn drive_player(w: *mut ld_world, _dt: f64, tick: i64, user: *mut c_void) -> i32 {
    let s = &mut *(user as *mut HostState);
    const VX: [f32; 4] = [3.0, 0.0, -3.0, 0.0];
    const VZ: [f32; 4] = [0.0, 3.0, 0.0, -3.0];
    let mut st = [0f32; 13];
    if ld_body_get_state(w, s.player, st.as_mut_ptr()) != LD_OK {
        return 1;
    }
    let k = ((tick / 60) % 4) as usize;
    s.pre_calls += 1;
    if ld_body_set_velocity(w, s.player, VX[k], st[8], VZ[k], 0.0, 0.0, 0.0) == LD_OK { 0 } else { 2 }
}

fn main() {
    unsafe {
        println!("abi {}", ld_abi_version());
        let mut w: *mut ld_world = core::ptr::null_mut();
        if ld_world_create(1.0 / 60.0, 0.0, -9.8, 0.0, &mut w) != LD_OK {
            println!("create failed");
            std::process::exit(1);
        }
        ld_body_add_box(w, 0.0, -0.5, 0.0, 20.0, 0.5, 20.0, 0.0, 1);
        for i in 0..4 {
            for k in 0..2 {
                ld_body_add_box(w, -3.0 + 2.0 * i as f32, 0.25 + 0.51 * k as f32, 2.0, 0.25, 0.25, 0.25, 1.0, 0);
            }
        }
        for i in 0..3 {
            ld_body_add_sphere(w, -2.0 + 2.0 * i as f32, 1.0 + 0.5 * i as f32, -2.0, 0.3, 0.5, 0);
        }
        let mut s = HostState { player: 0, pre_calls: 0 };
        s.player = ld_body_add_box(w, 0.0, 0.4, 0.0, 0.4, 0.4, 0.4, 2.0, 0);
        ld_world_add_system(w, LD_PHASE_PRE, Some(drive_player), &mut s as *mut HostState as *mut c_void);
        for _ in 0..120 {
            if ld_world_step(w, 1.0 / 60.0) < 0 {
                println!("step failed");
                std::process::exit(1);
            }
        }
        let ran = ld_world_step_ticks(w, 120);
        let mut h: u64 = 0;
        ld_world_hash(w, &mut h);
        println!("rs_ran {}", ran);
        println!("rs_hash {:016x}", h);
        println!("rs_pre {}", s.pre_calls);
        println!("rs_stale {}", ld_body_alive(w, s.player | (7i64 << 32)));
        println!("rs_destroy {}", ld_world_destroy(w));
    }
}
