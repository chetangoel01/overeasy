import Foundation
import UIKit
import XCTest
@testable import Ladle

/// The resolver's contract, in three parts: it covers enough of the real
/// library to be worth shipping, it never draws the wrong thing, and every
/// slug it can name is really in the bundle.
final class IngredientIconResolverTests: XCTestCase {

    // MARK: - Coverage

    /// The floor the tables have to clear on the real library's ingredient
    /// names. Measured, not chosen: matching the raw name against the slugs
    /// with no tables at all reaches 37.8%, and the synonym and
    /// default-variety tables take it to 78.2%. The floor sits just under
    /// that so the tables can only be improved, never quietly regressed.
    private static let coverageFloor = 0.78

    func testTablesClearTheCoverageFloorOnTheRealLibrary() throws {
        let corpus = try Self.corpus()
        XCTAssertGreaterThan(
            corpus.count, 100,
            "the fixture should carry the whole library, not a sample"
        )

        var resolved = 0
        var resolvedOccurrences = 0
        var occurrences = 0
        var misses: [String] = []
        for entry in corpus {
            occurrences += entry.count
            if IngredientIconResolver.slug(for: entry.name) != nil {
                resolved += 1
                resolvedOccurrences += entry.count
            } else {
                misses.append(entry.name)
            }
        }

        let distinct = Double(resolved) / Double(corpus.count)
        let weighted = Double(resolvedOccurrences) / Double(occurrences)
        print(
            """
            ingredient icon coverage
              distinct names: \(resolved)/\(corpus.count) \
            (\(Self.percent(distinct)))
              occurrences:    \(resolvedOccurrences)/\(occurrences) \
            (\(Self.percent(weighted)))
              unresolved:     \(misses.sorted().joined(separator: ", "))
            """
        )

        XCTAssertGreaterThanOrEqual(
            distinct, Self.coverageFloor,
            "coverage fell to \(Self.percent(distinct)) on \(corpus.count) "
                + "names; unresolved: \(misses.sorted())"
        )
    }

    /// Dropping the pantry containers is the option the issue thread nearly
    /// took. This is what it would have cost: the set paints produce, meat
    /// and dairy and puts every oil, spice, sauce, pulse and sweetener in a
    /// tinted jar instead, so the bare rows would have gone from one in five
    /// to three in five. Measured here rather than asserted in a pull
    /// request, so the decision can be revisited against a number.
    func testExcludingContainersCostsMostOfTheCoverage() throws {
        let corpus = try Self.corpus()
        let withContainers = corpus.filter {
            IngredientIconResolver.slug(for: $0.name) != nil
        }.count
        let illustratedOnly = corpus.filter {
            IngredientIconResolver.slug(for: $0.name, includesContainers: false)
                != nil
        }.count

        print(
            "ingredient icon coverage without containers: "
                + "\(illustratedOnly)/\(corpus.count) "
                + "(\(Self.percent(Double(illustratedOnly) / Double(corpus.count))))"
        )
        XCTAssertGreaterThanOrEqual(
            withContainers - illustratedOnly, 70,
            "the containers should be carrying most of the pantry"
        )
        XCTAssertLessThan(
            Double(illustratedOnly) / Double(corpus.count), 0.45,
            "illustrated-only coverage should be well under half"
        )
    }

    func testContainerSlugsAreWithheldWhenContainersAreExcluded() {
        XCTAssertEqual(IngredientIconResolver.slug(for: "soy sauce"), "soy-sauce")
        XCTAssertNil(
            IngredientIconResolver.slug(
                for: "soy sauce",
                includesContainers: false
            )
        )
        // A painted ingredient is unaffected either way.
        XCTAssertEqual(
            IngredientIconResolver.slug(for: "garlic", includesContainers: false),
            "garlic"
        )
    }

    // MARK: - Never the wrong art

    /// Names the set has no honest answer for. Every one of these has an
    /// obvious wrong answer a substring matcher would have reached for, and
    /// the issue is explicit that wrong art is worse than none: a cook reads
    /// the picture before the words.
    func testNamesWithNoHonestIconResolveToNothing() {
        let mustNotResolve = [
            // The classic substring traps.
            "peanut butter",        // not butter-salted, not peanut
            "almond milk",          // not almond, not milk-whole
            "coconut water",        // not coconut, not milk-coconut
            "oyster mushrooms",     // not oysters, not oyster-sauce
            "chicken mince",        // no ground-chicken art exists
            "potato rolls",         // not potato-russet
            "egg roll wrappers",    // not egg-chicken
            "pumpkin spice",        // not pumpkin, not pumpkin-puree
            "garlic bread",         // not garlic, not bread-white
            "cream of tartar sauce",

            // Genuinely absent from the set, as the issue records.
            "paneer",
            "tamarind",
            "water",
            "cottage cheese",
            "pecorino romano",
            "fontina cheese",
            "ground turkey",
            "marinara sauce",

            // A fresh tomato has no painting — only the canned forms. It
            // must not fall through to a can.
            "tomatoes",
            "beefsteak tomato",

            // Too vague, or two ingredients in one row. A single picture
            // would be a claim the row does not make.
            "salt and pepper",
            "parsley and chives",
            "fresh herbs",
            "spices",
            "beans",
            "cheese",
            "noodles",
            "unknown ingredient",
        ]

        for name in mustNotResolve {
            XCTAssertNil(
                IngredientIconResolver.slug(for: name),
                "\(name) should have no icon, got "
                    + String(describing: IngredientIconResolver.slug(for: name))
            )
        }
    }

    /// The other half of the same contract: names that look like traps but
    /// have a correct answer must reach it, not be refused out of caution.
    func testNamesThatLookLikeTrapsStillReachTheRightSlug() {
        let expected: KeyValuePairs<String, String> = [
            // Compound words the tokeniser must not split.
            "eggplant": "eggplant",
            "buttermilk": "buttermilk",
            "butternut squash": "butternut-squash",
            "cornstarch": "cornstarch",

            // Word order the set reverses.
            "coconut milk": "milk-coconut",
            "chicken stock": "stock-chicken",
            "chicken broth": "stock-chicken",
            "rice vinegar": "vinegar-rice",
            "cream cheese": "cheese-cream",
            "feta": "cheese-feta",
            "hearts of palm": "hearts-of-palm",
            "lemon juice": "lemon",
            "zest of 1 lemon": "lemon",

            // Qualified spices, where the qualifier is the whole point.
            "onion powder": "onion-powder",
            "garlic powder": "garlic-powder",
            "curry powder": "curry-powder",
            "coriander powder": "coriander-ground",
            "ground cumin": "cumin-ground",
            "cumin seeds": "cumin-seed",

            // Plurals the blunt -s rule gets wrong on one side only.
            "curry leaves": "curry-leaves",
            "bay leaves": "bay-leaf",
            "bay leaf": "bay-leaf",

            // Preparation and qualifier words that must fall away.
            "finely chopped garlic": "garlic",
            "boneless skin-on chicken thighs": "chicken-thigh",
            "96% ground beef": "beef-ground",
            "low-sodium soy sauce": "soy-sauce",
            "fat free evaporated milk": "evaporated-milk",
            "yukon gold potatoes": "potato-yukon",
            "crumbled feta": "cheese-feta",
            "basil (for the ricotta topping)": "basil-fresh",

            // Diacritics and British spellings.
            "fresh gruyère": "cheese-gruyere",
            "tomato purée": "tomato-paste",
            "green chillies": "green-chiles",
            "courgette": "zucchini",

            // Synonyms and defaults, the tables' whole reason to exist.
            "green onion": "scallion",
            "fresh coriander": "cilantro",
            "eggs": "egg-chicken",
            "butter": "butter-salted",
            "flour": "flour-all-purpose",
            "salt": "salt-kosher",
            "onion": "onion-yellow",
            "black pepper": "black-pepper-ground",
            "extra-virgin olive oil": "olive-oil-evoo",

            // The literal pass, which is the only thing keeping these apart.
            "diced tomatoes": "tomatoes-diced",
            "crushed tomatoes": "tomatoes-crushed",
            "cinnamon stick": "cinnamon-stick",
            "cloves": "clove",
            "3 cloves garlic": "garlic",
        ]

        for (name, slug) in expected {
            XCTAssertEqual(
                IngredientIconResolver.slug(for: name), slug,
                "\(name) should resolve to \(slug)"
            )
        }
    }

    func testEmptyAndPunctuationOnlyNamesResolveToNothing() {
        for name in ["", "   ", "—", "()", "1", "1/2"] {
            XCTAssertNil(IngredientIconResolver.slug(for: name))
        }
    }

    // MARK: - The tables cannot name art that is not there

    func testEveryTableTargetIsInTheCatalogue() {
        let unknown = IngredientIconResolver.tableTargets
            .subtracting(IngredientIconCatalogue.all)
        XCTAssertTrue(
            unknown.isEmpty,
            "synonym or default-variety table names slugs the catalogue "
                + "does not have: \(unknown.sorted())"
        )
    }

    /// Two readable table keys can normalise onto the same token set, and
    /// then one silently wins. Catch that here rather than in a capture.
    func testTableKeysDoNotCollide() {
        let written = IngredientIconResolver.writtenTableEntryCounts
        let indexed = IngredientIconResolver.tableEntryCounts
        XCTAssertEqual(
            indexed.synonyms, written.synonyms,
            "two synonym keys normalise to the same tokens"
        )
        XCTAssertEqual(
            indexed.defaults, written.defaults,
            "two default-variety keys normalise to the same tokens"
        )
    }

    /// The generated Swift catalogue and the compiled asset catalogue come
    /// from one run of `Tools/ingredient-icons/build.sh`. This is the test
    /// that fails if only one of them was committed.
    func testEverySlugInTheCatalogueHasArtInTheBundle() {
        XCTAssertEqual(IngredientIconCatalogue.all.count, 469)
        XCTAssertEqual(IngredientIconCatalogue.illustrated.count, 223)
        XCTAssertEqual(IngredientIconCatalogue.containers.count, 246)

        let missing = IngredientIconCatalogue.all.filter {
            UIImage(named: $0) == nil
        }
        XCTAssertTrue(
            missing.isEmpty,
            "\(missing.count) catalogue slugs have no image in the app "
                + "bundle: \(missing.sorted().prefix(10))"
        )
    }

    // MARK: - Fixture

    private struct Entry: Decodable {
        let name: String
        let count: Int
    }

    private struct Corpus: Decodable {
        let names: [Entry]
    }

    /// The coverage corpus: every distinct ingredient name in the real
    /// library, with how often it occurs. Names and counts only — no recipe,
    /// user or quantity data travels with it.
    private static func corpus() throws -> [Entry] {
        let bundle = Bundle(for: IngredientIconResolverTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "ingredient-names", withExtension: "json"),
            "LadleTests/Fixtures/ingredient-names.json is not in the test "
                + "bundle; check the resources entry in project.yml"
        )
        return try JSONDecoder()
            .decode(Corpus.self, from: Data(contentsOf: url))
            .names
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
