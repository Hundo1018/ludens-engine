"""Fit the lattice force on a driven sphere to its velocity history
(ROADMAP 17.59): F_n = sum_k c_k v_{n-k}, k = 0..K, least squares, from the
CSV printed by experiments/exp_lbm_added_mass.mojo. Then, for a body of
mass m (lattice units, rho_f = 1) moved explicitly by that force,
v_{n+1} = v_n + F_n / m, report the spectral radius of the recurrence for
a few density ratios, plus two corrections:
  * virtual added mass, (m + m_a) (v_{n+1} - v_n) = F_n + m_a (v_n - v_{n-1});
  * implicit wall drag (Ladd & Verberg 2001), (m + z) (v_{n+1} - v_n) = F_n,
    z = C rho V: the part of F linear in this step's wall velocity is taken
    at the new velocity.

usage: pixi run python scripts/added_mass_fit.py file.csv [K]
"""

import sys

import numpy as np


def load(path):
    rows = np.loadtxt(path, delimiter=",", skiprows=1)
    return rows[:, 1], rows[:, 2]


def fit(v, f, k):
    n = len(v)
    a = np.stack([v[k - j : n - j] for j in range(k + 1)], axis=1)
    c, *_ = np.linalg.lstsq(a, f[k:], rcond=None)
    resid = f[k:] - a @ c
    return c, float(np.sqrt(np.mean(resid**2)) / np.sqrt(np.mean(f[k:] ** 2)))


def radius(c, m, ma, prev=True):
    """Spectral radius of (m + ma)(v1 - v0) = sum_k c_k v_{-k} + ma (v0 - v_{-1})
    (prev=False drops the last term: the implicit wall-drag scheme)."""
    k = len(c)
    mt = m + ma
    # state (v_0, v_{-1}, ..., v_{-(k)}) ; v1 = v0 + (sum c_k v_{-k} + ma (v0 - v_{-1})) / mt
    dim = max(k, 2) + 1
    t = np.zeros((dim, dim))
    t[0, 0] += 1
    if prev:
        t[0, 0] += ma / mt
        t[0, 1] -= ma / mt
    for j, cj in enumerate(c):
        t[0, j] += cj / mt
    for i in range(1, dim):
        t[i, i - 1] = 1
    return float(max(abs(np.linalg.eigvals(t))))


def main():
    path = sys.argv[1]
    kmax = int(sys.argv[2]) if len(sys.argv) > 2 else 6
    v, f = load(path)
    c, rel = fit(v, f, kmax)
    print("coefficients c_k (lattice), k = 0..%d:" % kmax, " ".join("%.3f" % x for x in c))
    print("relative residual %.4f" % rel)
    vol = 4.0 / 3.0 * np.pi * 27  # R = 3 cells
    print("sphere volume (cells) %.1f, potential-flow m_a = %.1f" % (vol, 0.5 * vol))
    for ratio in (2.0, 1.5, 1.0, 0.5, 0.2):
        m = ratio * vol
        row = ["ratio %.1f: plain %.3f" % (ratio, radius(c, m, 0))]
        for ca in (0.5, 1.0, 1.5, 2.0):
            row.append("C_a %.1f %.3f" % (ca, radius(c, m, ca * vol)))
        print("  " + "  ".join(row))
    print("implicit wall drag, z = C rho V (fit: -c_0 / V = %.2f):" % (-c[0] / vol))
    for ratio in (2.0, 1.0, 0.5, 0.2, 0.05):
        m = ratio * vol
        row = ["ratio %.2f:" % ratio]
        for cz in (0.25, 0.5, 0.68, 1.0):
            row.append("C %.2f %.3f" % (cz, radius(c, m, cz * vol, prev=False)))
        print("  " + "  ".join(row))


if __name__ == "__main__":
    main()
