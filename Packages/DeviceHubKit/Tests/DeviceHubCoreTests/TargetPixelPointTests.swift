import DeviceHubCore
import Testing

@Suite("Target pixel addressing")
struct TargetPixelPointTests {
    private let size = PixelSize(width: 1179, height: 2556)

    @Test("a point must name an existing pixel: finite, within 0...size-1")
    func addressablePixels() {
        #expect(TargetPixelPoint(x: 0, y: 0).isAddressable(in: size))
        #expect(TargetPixelPoint(x: 1178, y: 2555).isAddressable(in: size))
        #expect(!TargetPixelPoint(x: 1178.5, y: 10).isAddressable(in: size))
        #expect(!TargetPixelPoint(x: 10, y: 2555.5).isAddressable(in: size))
        #expect(!TargetPixelPoint(x: -0.1, y: 10).isAddressable(in: size))
        #expect(!TargetPixelPoint(x: .nan, y: 10).isAddressable(in: size))
        #expect(!TargetPixelPoint(x: 10, y: .infinity).isAddressable(in: size))
        #expect(!TargetPixelPoint(x: 0, y: 0).isAddressable(in: PixelSize(width: 0, height: 10)))
    }
}
