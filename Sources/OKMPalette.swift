// 由 okm-brand/generate.py 從 tokens.json（OKMaster 色彩計畫）產生，請勿手動修改。
import AppKit

/// OKMaster 色彩計畫：品牌色、色階（固定色）與語意色（淺色／深色）。
enum OKMPalette {
    /// `brand-navy`：品牌主色（取自主商標的圓形色塊，也就是字母 O）。代表商標中的「空間」，是線條立體感的底。Logo、頁首、主要按鈕、重點區塊。白字對比 13.4:1。
    static let brandNavy = hex(0x0B2C67)
    /// `brand-slate`：品牌輔色（取自主商標 M 的兩條灰藍線）。在商標中代表退後的背面，製造景深。插圖、圖示、裝飾、控制項邊框。白底對比僅 3.2:1，不可用於內文字。
    static let brandSlate = hex(0x8391AE)
    /// `brand-white`：品牌白（取自主商標的 K 與 M 的白色 V）。在商標中代表朝前的正面。深色底上的文字與 logo 反白。
    static let brandWhite = hex(0xFFFFFF)
    /// `navy-950`：最深海軍藍，深色模式陰影層與頁尾。
    static let navy950 = hex(0x050F26)
    /// `navy-900`：深色頁首、深色模式凹陷區塊。
    static let navy900 = hex(0x071D45)
    /// `navy-800`：= brand-navy，色階中的基準色。
    static let navy800 = hex(0x0B2C67)
    /// `navy-700`：主要按鈕 hover、深色模式中的品牌色塊。
    static let navy700 = hex(0x1A3F82)
    /// `navy-600`：主要按鈕 pressed、資訊類標示；白字對比 7.3:1。
    static let navy600 = hex(0x2C559C)
    /// `navy-400`：圖表次要系列、深色底上的連結裝飾。
    static let navy400 = hex(0x6A8BC8)
    /// `navy-200`：選取狀態底色、圖表淺色系列。
    static let navy200 = hex(0xB9C9E6)
    /// `navy-100`：品牌淺底：資訊提示、選中列。
    static let navy100 = hex(0xE3EAF6)
    /// `slate-700`：次要文字（淺色模式），白底對比 6.7:1。
    static let slate700 = hex(0x4E5C7A)
    /// `slate-600`：說明文字、placeholder，白底 5.1:1。
    static let slate600 = hex(0x5F6E8E)
    /// `slate-500`：= brand-slate，色階基準。
    static let slate500 = hex(0x8391AE)
    /// `slate-300`：停用狀態、淺色圖示。
    static let slate300 = hex(0xB8C1D3)
    /// `slate-200`：分隔線、卡片邊框。
    static let slate200 = hex(0xD7DDE8)
    /// `slate-100`：次要背景、表格斑馬紋。
    static let slate100 = hex(0xEDF0F5)
    /// `slate-50`：頁面底色（淺色模式）。
    static let slate50 = hex(0xF6F8FB)
    /// `aqua-600`：介面補充色。焦點環；白字 5.5:1。（水滴意象屬於 OKM Mimir 延伸商標，不代表主品牌。）
    static let aqua600 = hex(0x0F6FA3)
    /// `aqua-400`：深色模式的焦點、圖表強調系列。
    static let aqua400 = hex(0x56B8E6)
    /// `aqua-100`：補充色淺底：新功能標籤、提示框。
    static let aqua100 = hex(0xE2F3FB)
    /// `bg`：頁面背景。
    static let bg = dynamic("OKMBg", light: 0xF6F8FB, dark: 0x0A1630)
    /// `surface`：卡片、對話框、輸入框底色。
    static let surface = dynamic("OKMSurface", light: 0xFFFFFF, dark: 0x132245)
    /// `surface-sunken`：凹陷區、側欄、程式碼區塊。
    static let surfaceSunken = dynamic("OKMSurfaceSunken", light: 0xEDF0F5, dark: 0x0D1A38)
    /// `border`：分隔線與卡片邊框（裝飾性，不需 3:1）。
    static let border = dynamic("OKMBorder", light: 0xD7DDE8, dark: 0x24345A)
    /// `border-strong`：輸入框、核取方塊等控制項邊框，對 surface ≥3:1。
    static let borderStrong = dynamic("OKMBorderStrong", light: 0x8391AE, dark: 0x6A7DA3)
    /// `text`：主要文字，對 bg / surface ≥13:1。
    static let text = dynamic("OKMText", light: 0x0A1630, dark: 0xE6EBF3)
    /// `text-muted`：次要文字，對 bg / surface ≥6:1。
    static let textMuted = dynamic("OKMTextMuted", light: 0x4E5C7A, dark: 0xA9B6CF)
    /// `primary`：主要動作（按鈕底、選中狀態），文字用 on-primary。
    static let primary = dynamic("OKMPrimary", light: 0x0B2C67, dark: 0x9FB3D9)
    /// `primary-hover`：主要按鈕 hover。
    static let primaryHover = dynamic("OKMPrimaryHover", light: 0x1A3F82, dark: 0xB9C9E6)
    /// `on-primary`：primary 上的文字與圖示，兩種模式皆 ≥8:1。
    static let onPrimary = dynamic("OKMOnPrimary", light: 0xFFFFFF, dark: 0x0A1630)
    /// `accent`：連結、強調數據、進度。淺色值對白底 5.5:1、對 bg 5.2:1；深色值對 bg 6.9:1，小字連結也可使用。
    static let accent = dynamic("OKMAccent", light: 0x2F6AAD, dark: 0x6FA3E6)
    /// `focus-ring`：鍵盤焦點外框 2px。
    static let focusRing = dynamic("OKMFocusRing", light: 0x0F6FA3, dark: 0x56B8E6)
    /// `success`：成功、完成、正向數值。白底 4.8:1。
    static let success = dynamic("OKMSuccess", light: 0x1E7F7F, dark: 0x4EC0BA)
    /// `warning`：提醒、待處理。
    static let warning = dynamic("OKMWarning", light: 0xB45309, dark: 0xF0A04B)
    /// `danger`：錯誤、刪除、負向數值。搭配圖示，不只靠顏色。
    static let danger = dynamic("OKMDanger", light: 0xC0362C, dark: 0xF07A6E)

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static func dynamic(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        let lightColor = hex(light), darkColor = hex(dark)
        return NSColor(name: name) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}
