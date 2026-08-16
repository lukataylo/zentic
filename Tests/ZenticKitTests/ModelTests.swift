import Foundation
import Testing

@testable import ZenticKit

@Suite("Section kinds")
struct SectionKindTests {

    @Test("Code, tables, math and embeds are never sent to a model")
    func nonProseIsNotRewritable() {
        // This is a correctness rule, not a preference: a model asked to restyle a
        // code block silently renames identifiers, and asked to restyle a table
        // drops cells. See SectionKind.isRewritable.
        for kind in [SectionKind.code, .table, .math, .figure, .embed, .footnotes] {
            #expect(!kind.isRewritable, "\(kind.rawValue) must not be rewritable")
        }
    }

    @Test("Prose is rewritable")
    func proseIsRewritable() {
        for kind in [SectionKind.heading, .paragraph, .list, .quote] {
            #expect(kind.isRewritable)
        }
    }

    @Test("rewritableSections filters an extraction to prose only")
    func extractionFiltersToProse() {
        let sections = Sample.extraction.rewritableSections
        #expect(sections.count == 2)
        #expect(!sections.contains { $0.kind == .code })
    }
}

@Suite("Archetype")
struct ArchetypeTests {

    @Test("Only .app is exempt from restructuring")
    func appIsNeverRestructured() {
        #expect(!Archetype.app.isRestructurable)
        for archetype in [Archetype.article, .docs, .feed, .thread] {
            #expect(archetype.isRestructurable)
        }
    }
}

@Suite("Site recipes")
struct SiteRecipeTests {

    @Test("Inferred recipes expire so site redesigns are picked up")
    func inferredRecipesGoStale() {
        var recipe = Sample.recipe
        recipe.provenance = .inferred
        recipe.generatedAt = Date(timeIntervalSince1970: 0)

        #expect(recipe.isStale(asOf: Date(timeIntervalSince1970: Budget.recipeMaxAge + 1)))
        #expect(!recipe.isStale(asOf: Date(timeIntervalSince1970: Budget.recipeMaxAge - 1)))
    }

    @Test("Curated and user recipes never expire on a timer")
    func curatedRecipesDoNotGoStale() {
        let distantFuture = Date(timeIntervalSince1970: 10_000_000_000)

        for provenance in [SiteRecipe.Provenance.curated, .userOverride] {
            var recipe = Sample.recipe
            recipe.provenance = provenance
            recipe.generatedAt = Date(timeIntervalSince1970: 0)
            #expect(!recipe.isStale(asOf: distantFuture))
        }
    }

    @Test("A user override outranks a curated recipe, which outranks an inferred one")
    func provenanceOrdering() {
        #expect(SiteRecipe.Provenance.inferred < .curated)
        #expect(SiteRecipe.Provenance.curated < .userOverride)
    }

    @Test("Recipes from an older schema are treated as incompatible")
    func schemaVersioning() {
        var recipe = Sample.recipe
        recipe.schemaVersion = SiteRecipe.currentSchemaVersion - 1
        #expect(!recipe.isCompatible)
        #expect(Sample.recipe.isCompatible)
    }

    @Test("Identity combines origin and path pattern")
    func identity() {
        #expect(Sample.recipe.id == "https://example.com|/posts/*")
    }
}

@Suite("Provider tiers")
struct ProviderTierTests {

    @Test("On-device is the lowest tier, so it is the default fallback")
    func ordering() {
        #expect(ProviderTier.onDevice < .byoKey)
        #expect(ProviderTier.byoKey < .cloud)
        #expect(ProviderTier.allCases.min() == .onDevice)
    }
}

@Suite("Budgets")
struct BudgetTests {

    @Test("Duration converts to whole milliseconds for JavaScript")
    func durationConversion() {
        #expect(Budget.revealFailsafe.milliseconds == 1500)
        #expect(Budget.settleQuietPeriod.milliseconds == 60)
        #expect(Duration.seconds(2).milliseconds == 2000)
        #expect(Duration.milliseconds(1).milliseconds == 1)
    }

    @Test("The settle ceiling leaves headroom under the reveal failsafe")
    func settleFitsInsideFailsafe() {
        // If settling could outlast the failsafe, every slow page would reveal
        // unstyled and extraction would never get a chance to run.
        #expect(Budget.settleCeiling < Budget.revealFailsafe)
    }
}
