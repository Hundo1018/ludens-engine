// Write the VDB zip fixtures for tests/test_vdb_zip.mojo (ROADMAP 17.63).
// Built against the conda-forge OpenVDB 13.1 C++ package (pixi exec), not the
// project environment. usage: zipwrite_fixtures <dir>
//
// Same grid four ways: smooth values with compression 0 (raw), 1 (zip),
// 3 (zip | active mask), hashed noise values with 1 (zip), and blosc (4) with
// and without the active mask (6). Each grid also
// holds one active 8^3 tile (level 1) at (64,16,16) with value 2.5 and one
// active 128^3 tile (level 2) at (0,128,0) with value 1.5. Coordinates
// are non-negative; the value formulas are repeated in the Mojo test.
#include <openvdb/openvdb.h>
#include <openvdb/tools/LevelSetSphere.h>
#include <cstdint>
#include <iostream>
#include <string>

static float smooth(int i, int j, int k) { return 1.0f + 0.001f * float(i + j + k); }

static float noise(int i, int j, int k)
{
    int64_t h = (int64_t(i) * 73856093) ^ (int64_t(j) * 19349663) ^ (int64_t(k) * 83492791);
    return float(h & 0xffff) / 65536.0f;
}

static void write(const std::string& path, uint32_t mask, bool use_noise)
{
    openvdb::FloatGrid::Ptr g = openvdb::FloatGrid::create(3.0f);
    g->setName("field");
    g->setTransform(openvdb::math::Transform::createLinearTransform(0.1));
    openvdb::FloatGrid::Accessor acc = g->getAccessor();
    // a ball around (20,20,20) and a small blob past the 128-voxel boundary
    const int centers[2][3] = {{20, 20, 20}, {200, 20, 20}};
    for (const auto& c : centers) {
        const int r = c[0] == 20 ? 6 : 2;
        for (int i = c[0] - r; i <= c[0] + r; ++i)
            for (int j = c[1] - r; j <= c[1] + r; ++j)
                for (int k = c[2] - r; k <= c[2] + r; ++k)
                    if ((i - c[0]) * (i - c[0]) + (j - c[1]) * (j - c[1]) + (k - c[2]) * (k - c[2]) <= r * r)
                        acc.setValueOn(openvdb::Coord(i, j, k),
                            use_noise ? noise(i, j, k) : smooth(i, j, k));
    }
    // an active 8^3 tile outside the balls, in the same 128^3 block as the first
    g->tree().addTile(1, openvdb::Coord(64, 16, 16), 2.5f, true);
    // an active 128^3 tile (level 2) in a block with no balls
    g->tree().addTile(2, openvdb::Coord(0, 128, 0), 1.5f, true);
    openvdb::io::File f(path);
    f.setCompression(mask);
    openvdb::GridPtrVec grids;
    grids.push_back(g);
    f.write(grids);
    f.close();
}

int main(int argc, char** argv)
{
    if (argc != 2) { std::cerr << "usage: zipwrite_fixtures <dir>\n"; return 2; }
    openvdb::initialize();
    std::string d = argv[1];
    write(d + "/raw_smooth.vdb", 0, false);
    write(d + "/zip_smooth.vdb", 1, false);
    write(d + "/zip_mask_smooth.vdb", 3, false);
    write(d + "/zip_noise.vdb", 1, true);
    write(d + "/blosc_smooth.vdb", 4, false);
    write(d + "/blosc_mask_smooth.vdb", 6, false);

    // a level set sphere (radius 10, voxel size 1, half width 3): its inside
    // is -3 beyond the narrow band, which only an inactive-value read keeps
    openvdb::FloatGrid::Ptr ls = openvdb::tools::createLevelSetSphere<openvdb::FloatGrid>(
        10.0f, openvdb::Vec3f(30.0f, 30.0f, 30.0f), 1.0f, 3.0f);
    ls->setName("level_set");
    openvdb::io::File lf(d + "/levelset_sphere.vdb");
    lf.setCompression(6);
    openvdb::GridPtrVec lv;
    lv.push_back(ls);
    lf.write(lv);
    lf.close();
    return 0;
}
