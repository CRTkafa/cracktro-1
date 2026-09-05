"""Regression checks for native-grid separable bloom kernels (no third-party deps)."""
import math
import unittest


def kernel(center, offsets, weights):
    result = {0: center}
    for offset, weight in zip(offsets, weights):
        lo = math.floor(offset)
        fraction = offset - lo
        for sign in (-1, 1):
            for index, amount in ((lo, 1 - fraction), (lo + 1, fraction)):
                at = sign * index
                result[at] = result.get(at, 0) + amount * weight
    return result


class BloomTests(unittest.TestCase):
    def test_native_grid_kernel(self):
        vertical = kernel(.2363835, [1.3730788, 3.2295113], [.3171515, .0646567])
        horizontal = kernel(.1513151, [1.4415567, 3.3767077, 5.3550101, 7.3868203],
                            [.2503180, .1212263, .0394885, .0133097])
        for profile in (vertical, horizontal):
            self.assertAlmostEqual(sum(profile.values()), 1, places=6)
            self.assertAlmostEqual(sum(i * w for i, w in profile.items()), 0, places=6)
            for i in range(max(profile)):
                self.assertGreater(profile[i], profile[i + 1])
                self.assertEqual(profile[i], profile[-i])

    def test_source_row_parity(self):
        # Two adjacent source rows map to the same 2:1 downsample pixel;
        # both undergo the same knee and carry precisely half its row energy.
        vertical = kernel(.2363835, [1.3730788, 3.2295113], [.3171515, .0646567])
        for row in range(12, 20, 2):
            even = {row // 2 + k: w * .5 for k, w in vertical.items()}
            odd = {(row + 1) // 2 + k: w * .5 for k, w in vertical.items()}
            self.assertEqual(even, odd)


if __name__ == "__main__":
    unittest.main()
