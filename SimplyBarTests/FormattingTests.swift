import Foundation
import Testing

private let english = Locale(identifier: "en_US")
private let french = Locale(identifier: "fr_FR")

struct FormattingTests {
    @Test func percentRoundsAndClamps() {
        #expect(Format.percent(0.254, locale: english) == "25%")
        #expect(Format.percent(0.2286, decimals: 1, locale: english) == "22.9%")
        #expect(Format.percent(1.7, locale: english) == "100%")
        #expect(Format.percent(-0.2, locale: english) == "0%")
        #expect(Format.percent(.nan, locale: english) == "0%")
    }

    @Test func frenchUsesADecimalComma() {
        #expect(Format.percent(0.2286, decimals: 1, locale: french) == "22,9%")
        #expect(Format.diskGigabytes(108_560_000_000, locale: french) == "108,56")
    }

    @Test func diskIsDecimalAndMemoryIsBinary() {
        // Reference value: 108 560 000 000 free bytes read 108.56 GB (decimal gigabytes, as for disks).
        #expect(Format.diskGigabytes(108_560_000_000, locale: english) == "108.56")
        #expect(Format.diskGigabytes(1_234_000_000_000, decimals: 0, locale: english) == "1234")
        // 16 GiB of RAM reads 16.0, not 17.2.
        #expect(Format.memoryGigabytes(17_179_869_184, locale: english) == "16.0")
    }

    @Test func speedPicksTheReadableUnit() {
        #expect(Format.speedUnit(for: 0) == .kilobytes)
        #expect(Format.speedUnit(for: 999_949) == .kilobytes)
        #expect(Format.speedUnit(for: 999_950) == .megabytes)
        #expect(Format.speedUnit(for: 999_950_000) == .gigabytes)

        let small = Format.speed(1_500, locale: english)
        #expect(small.value == "1.5" && small.unit == .kilobytes)
        let large = Format.speed(12_340_000, decimals: 2, locale: english)
        #expect(large.value == "12.34" && large.unit == .megabytes)
        #expect(Format.speed(-5, locale: english).value == "0.0")
        #expect(Format.speed(.infinity, locale: english).value == "0.0")
    }

    @Test func chartScaleRoundsTheTopUp() {
        #expect(ChartScale(values: [0.37], minimum: 0.1).top == 0.5)
        #expect(ChartScale(values: [0.05], minimum: 0.1).top == 0.1)
        #expect(ChartScale(values: [830_000], minimum: 10_000).top == 1_000_000)
        #expect(ChartScale(values: [180_000], minimum: 10_000).top == 200_000)
        #expect(ChartScale(values: [210_000], minimum: 10_000).top == 250_000)
        #expect(ChartScale(values: [], minimum: 0).top == 1)
        #expect(ChartScale(values: [.nan], minimum: 0.1).top == 0.1)

        let scale = ChartScale(values: [40], minimum: 1)
        #expect(scale.half == 25)
        #expect(scale.fraction(of: 25) == 0.5)
        #expect(scale.fraction(of: 90) == 1)
        #expect(scale.fraction(of: -3) == 0)
    }

    @Test func loadColorGoesFromGreenToRed() {
        #expect(Palette.loadRGB(0.1) == Palette.greenRGB)
        #expect(Palette.loadRGB(0.95) == Palette.redRGB)
        #expect(Palette.loadRGB(0.55) == Palette.yellowRGB)
        let middle = Palette.loadRGB(0.45)
        #expect(middle.red > Palette.greenRGB.red && middle.red < Palette.yellowRGB.red)
    }
}

struct ModelTests {
    @Test func historyKeepsTheMostRecentValues() {
        var history = History(capacity: 3)
        for value in 1...5 { history.append(Double(value)) }
        #expect(history.values == [3, 4, 5])
        #expect(history.last(2) == [4, 5])
        #expect(History(capacity: 0).capacity == 1)
        #expect(History(capacity: 2, values: [1, 2, 3]).values == [2, 3])
    }

    @Test func memoryPercentagesMatchTheReferenceValues() {
        // 16 GiB Mac: 1.8 GiB wired and 1.8 GiB compressed give a 22.8 % pressure.
        let gib = 1_073_741_824.0
        let memory = MemorySample(total: 16 * gib, app: 4 * gib, wired: 1.85 * gib, compressed: 1.8 * gib)
        #expect(abs(memory.pressure - 0.228) < 0.001)
        #expect(abs(memory.used - 7.65 * gib) < 1)
        #expect(abs(memory.usage - 7.65 / 16) < 1e-9)
        #expect(abs(memory.free - 8.35 * gib) < 1)
        #expect(MemorySample(total: 0, app: 1, wired: 1, compressed: 1).usage == 0)
    }

    @Test func diskUsedIsTotalMinusFree() {
        let disk = DiskSample(name: "Macintosh HD", total: 245_110_000_000, free: 108_560_000_000)
        #expect(disk.used == 136_550_000_000)
        #expect(Format.percent(disk.usage, decimals: 1, locale: english) == "55.7%")
        #expect(DiskSample(name: "", total: 10, free: 20).used == 0)
    }

    @Test func cpuTotalIsUserPlusSystem() {
        #expect(abs(CPUSample(user: 0.2, system: 0.1, idle: 0.7, perCore: []).total - 0.3) < 1e-12)
        #expect(CPUSample(user: 0.9, system: 0.3, idle: 0, perCore: []).total == 1)
    }

    @Test func bluetoothLowestLevel() {
        let device = BluetoothDevice(name: "Buds", levels: [
            .init(part: .left, percent: 80), .init(part: .right, percent: 35), .init(part: .caseBattery, percent: 60),
        ])
        #expect(device.lowest == 35)
        #expect(BluetoothDevice(name: "Keyboard", levels: []).lowest == nil)
    }

    @Test func widgetPayloadSurvivesTheSharedFile() throws {
        let payload = WidgetPayload(
            date: Date(timeIntervalSince1970: 1_790_000_000),
            cpu: CPUSample(user: 0.2, system: 0.05, idle: 0.75, perCore: [0.3, 0.2]),
            cpuHistory: [0.1, 0.2],
            memory: MemorySample(total: 16, app: 4, wired: 2, compressed: 1),
            network: NetworkSample(upload: 1_000, download: 50_000),
            uploadHistory: [1, 2], downloadHistory: [3, 4],
            disk: DiskSample(name: "", total: 100, free: 40)
        )
        let decoded = try SharedStore.decode(SharedStore.encode(payload))
        #expect(decoded == payload)
        #expect(SharedStore.isFresh(payload, now: payload.date.addingTimeInterval(60)))
        #expect(!SharedStore.isFresh(payload, now: payload.date.addingTimeInterval(SharedStore.freshness + 1)))
    }

    @Test func olderOrBrokenSharedFilesDoNotCrash() throws {
        // Written by an older version, with a GPU the widgets never drew: the extra key is ignored.
        let older = Data("""
            {"date":1790000000,"cpuHistory":[],"uploadHistory":[],"downloadHistory":[],
             "gpu":{"model":"GPU","utilization":0.1}}
            """.utf8)
        #expect(try SharedStore.decode(older).date == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(throws: (any Error).self) { try SharedStore.decode(Data("not json".utf8)) }
        #expect(throws: (any Error).self) { try SharedStore.decode(Data(#"{"date":"yesterday"}"#.utf8)) }
    }
}
