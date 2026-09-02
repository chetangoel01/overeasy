import Foundation

/// Maps an ingredient's name onto a slug in the bundled icon catalogue.
///
/// A pure function over static tables: no bundle, no network, no state. The
/// coverage it reaches is measured on the real library's ingredient names in
/// `IngredientIconResolverTests`, and the tables are only allowed to grow
/// against that measurement.
///
/// **It never matches on a substring.** "peanut butter" containing "butter"
/// is the whole problem: the wrong painting beside an ingredient is worse
/// than no painting, because a cook reads the picture before the words. So
/// every step here compares *whole token sets* — the name and the slug are
/// pushed through the same normaliser and must come out equal — and the only
/// way a name reaches a slug it does not literally spell is through a table
/// somebody wrote on purpose.
///
/// Three passes, each looser than the last, and the first hit wins:
///
/// 1. **Literal.** Every token the name carries. "diced tomatoes" finds
///    `tomatoes-diced` here, and only here.
/// 2. **Without preparation words.** "finely chopped garlic" becomes
///    `garlic`; the set never paints a chopped clove differently.
/// 3. **Without soft qualifiers.** "low-sodium soy sauce" becomes
///    `soy-sauce`. These are dropped last because they are often the whole
///    point — `basil-fresh` and `basil-dried` are different pictures, and
///    pass 1 has already had its chance to tell them apart.
///
/// Within a pass: the slug index, then the synonym table, then the
/// default-variety table, then the same three with one token substituted
/// (`powder`→`ground`, `broth`→`stock`) — late enough that `garlic-powder`
/// and `curry-powder` win before `powder` ever becomes `ground`.
enum IngredientIconResolver {

    /// The catalogue slug to draw beside `name`, or `nil` when the set has
    /// no honest answer — paneer, tamarind, a fresh tomato, plain water, or
    /// a row that names two things at once.
    ///
    /// - Parameter includesContainers: Whether the tinted pantry containers
    ///   are eligible. They are: the set puts every oil, spice, sauce and
    ///   pulse in a jar or bottle rather than painting it, so excluding them
    ///   drops coverage on the real library from 78% to 39%. The flag exists
    ///   so that decision stays visible and reversible, not because any
    ///   caller currently turns it off.
    static func slug(
        for name: String,
        includesContainers: Bool = true
    ) -> String? {
        let eligible = IngredientIconCatalogue.eligible(
            includesContainers: includesContainers
        )
        for precision in Precision.allCases {
            let key = key(for: name, at: precision)
            if key.isEmpty { continue }
            if let hit = lookup(key, in: eligible) { return hit }
            for (spoken, filed) in variants where key.contains(spoken) {
                var substituted = key
                substituted.remove(spoken)
                substituted.insert(filed)
                if let hit = lookup(substituted, in: eligible) { return hit }
            }
        }
        return nil
    }

    // MARK: - Matching

    /// How much of the name a pass is willing to throw away.
    private enum Precision: CaseIterable {
        case literal
        case withoutPreparation
        case withoutQualifiers
    }

    private static func lookup(
        _ key: Set<String>,
        in eligible: Set<String>
    ) -> String? {
        for table in [slugIndex, synonymIndex, defaultVarietyIndex] {
            if let slug = table[key], eligible.contains(slug) { return slug }
        }
        return nil
    }

    // MARK: - Normalisation

    /// The token set a name reduces to at a given precision.
    ///
    /// Dropping every token would make a name match anything, so a key that
    /// empties out keeps what it started with: "cloves" the spice survives
    /// even though "cloves" is also the unit in "3 cloves garlic".
    private static func key(
        for value: String,
        at precision: Precision
    ) -> Set<String> {
        let all = baseTokens(value)
        guard precision != .literal else { return Set(all) }
        let kept = all.filter { token in
            if preparations.contains(token) { return false }
            if precision == .withoutQualifiers,
               softQualifiers.contains(token) { return false }
            return true
        }
        return Set(kept.isEmpty ? all : kept)
    }

    /// A slug's own token set. Slugs are canonical — every word in one was
    /// chosen — so only the connectives come out, never a preparation word.
    /// Dropping those too would collapse `tomatoes-crushed` and
    /// `tomatoes-diced` onto the same key, and then a fresh tomato would get
    /// a can of tomatoes drawn beside it.
    private static func key(forSlug slug: String) -> Set<String> {
        Set(baseTokens(slug.replacingOccurrences(of: "-", with: " ")))
    }

    private static func baseTokens(_ value: String) -> [String] {
        withoutParentheticals(value)
            .folding(
                options: .diacriticInsensitive,
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map { fold(String($0)) }
            .filter { token in
                token.count > 1
                    && !token.allSatisfy(\.isNumber)
                    && !connectives.contains(token)
            }
    }

    /// "basil (for the ricotta topping)" is a note to the cook, not part of
    /// the ingredient's name.
    private static func withoutParentheticals(_ value: String) -> String {
        var result = ""
        var depth = 0
        for character in value {
            switch character {
            case "(", "[":
                depth += 1
            case ")", "]":
                depth = max(0, depth - 1)
                result.append(" ")
            default:
                if depth == 0 { result.append(character) }
            }
        }
        return result
    }

    /// Fold a plural away so the name and the slug meet in the middle.
    ///
    /// The blunt rule is the one `nutrition/calculator.py` already uses —
    /// drop a trailing "s" from anything longer than three characters — and
    /// it is applied to both sides, so even the words it mangles
    /// (`asparagus`→`asparagu`) still match by construction. `irregulars`
    /// covers the forms where only one side would be mangled: a recipe's
    /// "bay leaves" against the set's `bay-leaf`.
    private static func fold(_ token: String) -> String {
        if let irregular = irregulars[token] { return irregular }
        guard token.count > 3, token.hasSuffix("s") else { return token }
        return String(token.dropLast())
    }

    // MARK: - Tables

    /// Plurals the blunt rule gets wrong, and the words British and Indian
    /// recipe English uses for things the set files under another spelling.
    private static let irregulars: [String: String] = [
        "leaves": "leaf",
        "loaves": "loaf",
        "tomatoes": "tomato",
        "potatoes": "potato",
        "berries": "berry",
        "anchovies": "anchovy",
        "peas": "pea",
        "chilies": "chili",
        "chillies": "chili",
        "chilis": "chili",
        "chilli": "chili",
        "chiles": "chili",
        "chile": "chili",
        "yoghurt": "yogurt",
        "courgette": "zucchini",
        "aubergine": "eggplant",
        "rocket": "arugula",
        "rucola": "arugula",
        "prawns": "shrimp",
        "prawn": "shrimp",
    ]

    /// Grammar. Never meaningful on either side, so these come out of slugs
    /// too — which is how "hearts of palm" reaches `hearts-of-palm`.
    private static let connectives = words("""
        an the of for and or with without such including
        """)

    /// What a cook does to an ingredient before it goes in the pan. The set
    /// paints the ingredient, never the knife work, so these are dropped
    /// from pass 2 onward. Words the set *does* distinguish — ground, whole,
    /// seed, fresh, dried, salted — are deliberately absent.
    private static let preparations = words("""
        chopped finely fine minced diced sliced thinly thin shaved grated
        crushed cracked cubed halved quartered shredded torn julienned
        smashed peeled trimmed cleaned rinsed drained melted softened
        beaten whisked crumbled roughly coarsely lightly thickly pitted
        seeded deseeded stemmed zested juiced squeezed sifted skinned
        deboned rough packed heaping level scant generous optional divided
        plus more serve garnish garnished topping needed taste rind
        large small medium jumbo baby mini gold golden
        good quality best free range organic homemade store bought
        room temperature
        piece bunch head clove sprig stalk package
        handful pinch dash splash
        """)

    /// Meaningful sometimes, noise the rest of the time. `duck-fat` and
    /// `basil-fresh` need these words; "fat free evaporated milk" and
    /// "low-sodium soy sauce" need them gone. Trying them both ways, in that
    /// order, is cheaper than deciding which is which.
    private static let softQualifiers = words("""
        fresh freshly dried raw ripe whole toasted roasted uncooked cooked
        boneless skinless skin bone on off in soft hard
        extra virgin light dark sweet unsweetened plain mild
        frozen canned jarred prepared steamed boiled day old
        fat free low reduced sodium skim nonfat lite
        red green white black yellow brown
        """)

    /// What the recipe calls it, against what the set filed it under. Every
    /// entry here is a judgement someone made; none of them fall out of the
    /// tokens.
    private static let synonyms: [String: String] = [
        // Alliums and herbs, where the two Englishes disagree outright.
        "green onion": "scallion",
        "spring onion": "scallion",
        "fresh coriander": "cilantro",
        "coriander leaves": "cilantro",
        "cilantro leaves": "cilantro",
        "chinese parsley": "cilantro",
        "rucola arugula rocket": "arugula",

        // The set files cheeses noun-first; recipes almost never do.
        "feta": "cheese-feta",
        "parmesan": "cheese-parmesan",
        "parmigiano": "cheese-parmesan",
        "parmigiano reggiano": "cheese-parmesan",
        "mozzarella": "cheese-mozzarella",
        "ricotta": "cheese-ricotta",
        "cheddar": "cheese-cheddar",
        "gruyere": "cheese-gruyere",
        "brie": "cheese-brie",
        "halloumi": "cheese-halloumi",
        "cotija": "cheese-cotija",
        "mascarpone": "cheese-mascarpone",
        "blue cheese": "cheese-blue",
        "goat cheese": "cheese-goat",

        // Pasta and noodles, filed under their material.
        "orzo": "pasta-orzo",
        "penne": "pasta-penne",
        "spaghetti": "pasta-spaghetti",
        "fettuccine": "pasta-fettuccine",
        "farfalle": "pasta-farfalle",
        "fusilli": "pasta-fusilli",
        "macaroni": "pasta-macaroni",
        "rigatoni": "pasta-rigatoni",
        "lasagna": "pasta-lasagna",
        "lasagne": "pasta-lasagna",
        "lasagna noodles": "pasta-lasagna",
        "udon": "noodles-udon",
        "ramen": "noodles-ramen",
        "soba": "noodles-soba",
        "rice noodles": "noodles-rice",
        "egg noodles": "noodles-egg",

        // Bread.
        "sourdough": "bread-sourdough",
        "sourdough bread": "bread-sourdough",
        "sourdough toast": "bread-sourdough",
        "white bread": "bread-white",
        "whole wheat bread": "bread-whole-wheat",

        // Chilli and pepper, the corner where a wrong guess is easiest.
        "red pepper flakes": "chili-flakes",
        "red chili flakes": "chili-flakes",
        "crushed red pepper": "chili-flakes",
        "chili flake": "chili-flakes",
        "cayenne pepper": "cayenne",
        "peppercorn": "black-pepper-whole",
        "black peppercorn": "black-pepper-whole",
        "red chili powder": "chili-powder",
        "kashmiri red chili powder": "chili-powder",
        "capsicum": "bell-pepper-red",

        // Oils. "Neutral" is a property, not a plant; the set's neutral
        // bottle is canola.
        "neutral oil": "canola-oil",
        "vegetable oil": "canola-oil",
        "soybean oil": "canola-oil",
        "extra virgin olive oil": "olive-oil-evoo",
        "evoo": "olive-oil-evoo",

        // The juice or zest of a fruit is drawn as the fruit. A deliberate
        // exception to "never drop a head noun": the set has no art for
        // either form, and a lemon beside "lemon juice" reads correctly.
        "lemon juice": "lemon",
        "lime juice": "lime",
        "orange juice": "orange",
        "lemon zest": "lemon",
        "lime zest": "lime",
        "orange zest": "orange",

        // Pastes the set has no art for, shown as the thing itself.
        "ginger paste": "ginger",
        "garlic paste": "garlic",
        "ginger garlic paste": "ginger",
        "tomato puree": "tomato-paste",
        "tomato sauce": "tomato-paste",
        "passata": "tomato-paste",

        // Spelling and shape.
        "corn starch": "cornstarch",
        "corn flour": "cornstarch",
        "chick peas": "chickpeas",
        "garbanzo beans": "chickpeas",
        "black olives": "olives-kalamata",
        "sundried tomatoes": "sun-dried-tomatoes",
        "whipping cream": "heavy-cream",
        "double cream": "heavy-cream",
    ]

    /// Where the set is more specific than a recipe ever is. One default
    /// each, chosen so the commonest reading of the bare word is what the
    /// cook sees — and never chosen where the bare word is genuinely
    /// ambiguous, which is why "beans", "cheese", "noodles" and "peppers"
    /// are not here and stay unillustrated.
    private static let defaultVarieties: [String: String] = [
        "salt": "salt-kosher",
        "sugar": "sugar-granulated",
        "flour": "flour-all-purpose",
        "butter": "butter-salted",
        "egg": "egg-chicken",
        "onion": "onion-yellow",
        "oil": "canola-oil",
        "olive oil": "olive-oil-evoo",
        "sesame oil": "sesame-oil-toasted",
        "black pepper": "black-pepper-ground",
        "paprika": "paprika-sweet",
        "bell pepper": "bell-pepper-red",
        "cumin": "cumin-ground",
        "coriander": "coriander-ground",
        "cinnamon": "cinnamon-ground",
        "turmeric": "turmeric-ground",
        "mustard": "mustard-yellow",
        "miso": "miso-white",
        "yogurt": "yogurt-greek",
        "milk": "milk-whole",
        "rice": "rice-jasmine",
        "pasta": "pasta-spaghetti",
        "lentils": "lentils-brown",
        "oats": "oats-rolled",
        "yeast": "yeast-active-dry",
        "lettuce": "lettuce-romaine",
        "mushroom": "mushroom-button",
        "potato": "potato-russet",
        "sesame seeds": "sesame-seeds-white",
        "chocolate": "chocolate-bittersweet",
        "vanilla": "vanilla-extract",
        "vinegar": "vinegar-white",
        "wine": "wine-white",
        "stock": "stock-chicken",
        "cabbage": "cabbage-green",
        "grape": "grape-red",
        "apple": "apple-granny-smith",
        "tofu": "tofu-firm",
        "olives": "olives-green",
        "tortilla": "tortilla-flour",

        // The set paints these fresh and dried. A recipe that means dried
        // says "dried", so the bare word is the fresh one — one rule for all
        // of them rather than an argument per herb. Marjoram is the
        // exception the set forces: it has no fresh painting.
        "basil": "basil-fresh",
        "parsley": "parsley-flat",
        "thyme": "thyme-fresh",
        "rosemary": "rosemary-fresh",
        "oregano": "oregano-fresh",
        "sage": "sage-fresh",
        "dill": "dill-fresh",
        "mint": "mint-fresh",
        "tarragon": "tarragon-fresh",
        "marjoram": "marjoram-dried",
    ]

    /// One-token substitutions, tried only after the literal tokens have
    /// failed. "coriander powder" becomes `coriander-ground` this way, while
    /// `garlic-powder` still wins on its own spelling.
    private static let variants: [(String, String)] = [
        ("powder", "ground"),
        ("broth", "stock"),
        ("bouillon", "stock"),
    ]

    // MARK: - Indexes

    private static let slugIndex: [Set<String>: String] = IngredientIconCatalogue
        .all
        .sorted()
        .reduce(into: [:]) { index, slug in
            let key = key(forSlug: slug)
            if index[key] == nil { index[key] = slug }
        }

    private static let synonymIndex = index(synonyms)
    private static let defaultVarietyIndex = index(defaultVarieties)

    private static func index(_ table: [String: String]) -> [Set<String>: String] {
        table.reduce(into: [:]) { index, entry in
            index[key(for: entry.key, at: .withoutPreparation)] = entry.value
        }
    }

    private static func words(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: \.isWhitespace).map { fold(String($0)) })
    }
}

// MARK: - Test access

extension IngredientIconResolver {
    /// The slugs the tables can emit, for the test that checks every one of
    /// them is really in the bundle. Not for production use: a call site
    /// wants `slug(for:)`.
    static var tableTargets: Set<String> {
        Set(synonyms.values).union(defaultVarieties.values)
    }

    /// How many distinct entries the tables hold once normalised, so a test
    /// can catch two readable keys silently collapsing onto one key.
    static var tableEntryCounts: (synonyms: Int, defaults: Int) {
        (synonymIndex.count, defaultVarietyIndex.count)
    }

    static var writtenTableEntryCounts: (synonyms: Int, defaults: Int) {
        (synonyms.count, defaultVarieties.count)
    }
}
