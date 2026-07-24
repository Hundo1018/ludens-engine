// Pure-JS reference implementation ("oracle") of SparseSet.
//
// In the full methodology the oracle is the NATIVE Mojo build (run under lldb,
// fully feature-complete) -- see STATUS.md. Until `mojo` is installable here,
// this JS mirror encodes the same canonical semantics so the differential
// harness has something authoritative to compare the wasm module against.
export function createOracle(fixedSize) {
  const sparse = new Array(fixedSize).fill(-1);
  const dense = [];
  return {
    contains(k) {
      if (k < 0 || k >= fixedSize) return false;
      const i = sparse[k];
      return i >= 0 && i < dense.length && dense[i] === k;
    },
    add(k) {
      if (k < 0 || k >= fixedSize) return;
      if (this.contains(k)) return;
      sparse[k] = dense.length;
      dense.push(k);
    },
    remove(k) {
      if (!this.contains(k)) return;
      const idx = sparse[k];
      const last = dense[dense.length - 1];
      dense[idx] = last;
      sparse[last] = idx;
      dense.pop();
      sparse[k] = -1;
    },
    len() {
      return dense.length;
    },
    dense() {
      return dense.slice();
    },
  };
}
