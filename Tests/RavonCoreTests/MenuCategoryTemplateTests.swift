import Testing
@testable import RavonCore

@Suite("MenuCategoryTemplate")
struct MenuCategoryTemplateTests {

    @Test("Uzbek cuisine returns correct categories")
    func uzbek() {
        let categories = MenuCategoryTemplate.suggestions(for: "uzbek")
        #expect(categories.contains("Шашлыки"))
        #expect(categories.contains("Самса и выпечка"))
        #expect(!categories.isEmpty)
    }

    @Test("Cyrillic alias returns same as Latin")
    func cyrillicAlias() {
        let latin = MenuCategoryTemplate.suggestions(for: "uzbek")
        let cyrillic = MenuCategoryTemplate.suggestions(for: "узбекская")
        #expect(latin == cyrillic)
    }

    @Test("Case insensitive matching")
    func caseInsensitive() {
        let lower = MenuCategoryTemplate.suggestions(for: "uzbek")
        let upper = MenuCategoryTemplate.suggestions(for: "UZBEK")
        #expect(lower == upper)
    }

    @Test("Unknown cuisine returns defaults")
    func unknown() {
        let categories = MenuCategoryTemplate.suggestions(for: "martian")
        #expect(categories.contains("Основные блюда"))
        #expect(categories.contains("Напитки"))
        #expect(!categories.isEmpty)
    }

    @Test("Each known cuisine returns non-empty array", arguments: [
        "uzbek", "tajik", "european", "fast food", "asian", "coffee",
        "узбекская", "таджикская", "европейская", "фастфуд", "азиатская", "кофейня"
    ])
    func allCuisinesNonEmpty(cuisine: String) {
        let categories = MenuCategoryTemplate.suggestions(for: cuisine)
        #expect(!categories.isEmpty)
    }
}
