// Regenerate the natural-order test digests using the retained upstream code:
// nix develop -c clang++ -std=c++17 -O2 -DNDEBUG -ffunction-sections
//   -fdata-sections -Wl,--gc-sections -I. -Iinclude -Ilib/include
//   -Ithird_party/highway tests/unit/coeff_order_oracle.cc
//   lib/jxl/ac_strategy.cc -o "$TMPDIR/coeff-order-oracle"
// "$TMPDIR/coeff-order-oracle"
#include <cstdio>
#include <vector>
#include "lib/jxl/ac_strategy.h"

int main() {
	for (unsigned raw = 0; raw < jxl::AcStrategy::kNumValidStrategies; ++raw) {
		const auto s = jxl::AcStrategy::FromRawStrategy(raw);
		std::vector<jxl::coeff_order_t> order(64 * s.covered_blocks_x() * s.covered_blocks_y());
		s.ComputeNaturalCoeffOrder(order.data());
		uint64_t hash = 14695981039346656037ull;
		for (uint32_t coefficient : order) {
			hash ^= coefficient;
			hash *= 1099511628211ull;
		}
		printf("%u %zu 0x%016llx\n", raw, order.size(), (unsigned long long)hash);
	}
}
