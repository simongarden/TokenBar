import Testing

@Suite struct MeterScaleTests {
    @Test func segmentCountFollowsTheWindow() {
        #expect(MeterScale.segments(windowMinutes: 300, weeklyIfUnknown: false) == 10)      // 5 h
        #expect(MeterScale.segments(windowMinutes: 10080, weeklyIfUnknown: false) == 7)     // 1 week
        #expect(MeterScale.segments(windowMinutes: 1440, weeklyIfUnknown: true) == 10)      // a day is not weekly
        #expect(MeterScale.segments(windowMinutes: nil, weeklyIfUnknown: true) == 7)
        #expect(MeterScale.segments(windowMinutes: nil, weeklyIfUnknown: false) == 10)
    }

    @Test func fiveHourSegmentsAreTenPercentEach() {
        #expect(MeterScale.filled(percent: 0, segments: 10) == 0)
        #expect(MeterScale.filled(percent: 0.4, segments: 10) == 1)    // any usage shows
        #expect(MeterScale.filled(percent: 10, segments: 10) == 1)
        #expect(MeterScale.filled(percent: 10.1, segments: 10) == 2)
        #expect(MeterScale.filled(percent: 95, segments: 10) == 10)
        #expect(MeterScale.filled(percent: 100, segments: 10) == 10)
        #expect(MeterScale.filled(percent: 140, segments: 10) == 10)
    }

    @Test func weeklySegmentsAreAboutOneDayEach() {
        #expect(MeterScale.filled(percent: 14.2, segments: 7) == 1)    // within the first day's share
        #expect(MeterScale.filled(percent: 14.3, segments: 7) == 2)
        #expect(MeterScale.filled(percent: 42.8, segments: 7) == 3)    // three days' worth
        #expect(MeterScale.filled(percent: 50, segments: 7) == 4)
        #expect(MeterScale.filled(percent: 100, segments: 7) == 7)
        #expect(MeterScale.filled(percent: -3, segments: 7) == 0)
    }
}
