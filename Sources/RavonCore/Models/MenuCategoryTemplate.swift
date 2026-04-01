import Foundation

public struct MenuCategoryTemplate: Sendable {
    public static func suggestions(for cuisineType: String) -> [String] {
        switch cuisineType.lowercased() {
        case "uzbek", "узбекская":
            return ["Основные блюда", "Шашлыки", "Супы", "Салаты", "Самса и выпечка", "Напитки", "Десерты"]
        case "tajik", "таджикская":
            return ["Основные блюда", "Плов", "Шашлыки", "Супы", "Салаты", "Выпечка", "Напитки"]
        case "european", "европейская":
            return ["Закуски", "Основные блюда", "Паста", "Супы", "Салаты", "Десерты", "Напитки"]
        case "fast food", "фастфуд":
            return ["Бургеры", "Картошка фри", "Наггетсы", "Сэндвичи", "Напитки", "Десерты"]
        case "asian", "азиатская":
            return ["Суши и роллы", "Лапша", "Рис", "Супы", "Салаты", "Напитки"]
        case "coffee", "кофейня":
            return ["Кофе", "Чай", "Выпечка", "Десерты", "Сэндвичи"]
        default:
            return ["Основные блюда", "Закуски", "Супы", "Салаты", "Напитки", "Десерты"]
        }
    }
}
