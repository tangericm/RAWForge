import Foundation

/// Owns the user's selection and library, not the camera transaction. Views
/// observe this reference directly instead of republishing it on CaptureModel.
@MainActor
final class RecipeCoordinator: ObservableObject {
    @Published private(set) var selectedRecipe: Recipe?
    @Published private(set) var library: [Recipe] = []
    @Published private(set) var notice: String?
    @Published private(set) var lastOutcome: TakeOutcome?
    private let station: StationController
    private let recipes: RecipeStore
    private let selection: SelectedRecipeStore
    private let runs: ActiveRunStore
    private let loadLegacy: () -> ShotListStore.Stored?
    private let clearLegacy: () throws -> Void
    private var booted = false

    init(station: StationController, recipes: RecipeStore = RecipeStore(),
         selection: SelectedRecipeStore = SelectedRecipeStore(), runs: ActiveRunStore = ActiveRunStore(),
         loadLegacy: @escaping () -> ShotListStore.Stored? = ShotListStore.load,
         clearLegacy: @escaping () throws -> Void = ShotListStore.clearForMigration) {
        self.station = station
        self.recipes = recipes
        self.selection = selection
        self.runs = runs
        self.loadLegacy = loadLegacy
        self.clearLegacy = clearLegacy
    }

    var validation: RecipeValidation? {
        guard let recipe = selectedRecipe, let report = station.report else { return nil }
        return RecipeValidator.validate(recipe, against: report)
    }

    func boot(report: CapabilityReport) throws {
        guard !booted else { return }
        station.report = report
        _ = try recipes.migrateShotListIfNeeded(loadLegacy(), clearLegacy: clearLegacy)
        if report.canCapture { selectedRecipe = try recipes.ensureStarterSelected(report: report) }
        library = try recipes.all()
        notice = try station.recoverActiveRun(using: runs)
        if let selectedRecipe { station.shotList = ShotList(entries: selectedRecipe.renderedEntries()) }
        station.startFlow()
        booted = true
    }

    func select(_ recipe: Recipe) throws {
        try requireIdle()
        guard let saved = try recipes.load(id: recipe.id, version: recipe.version) else {
            throw RecipeStore.Failure.missingRecipe
        }
        try selection.save(saved)
        selectedRecipe = saved
        station.shotList = ShotList(entries: saved.renderedEntries())
        notice = nil
        station.startFraming()
    }

    func save(_ draft: Recipe) throws {
        try requireIdle()
        let saved = try recipes.load(id: draft.id, version: 1) == nil
            ? recipes.create(draft) : recipes.saveVersion(draft)
        try select(saved)
        library = try recipes.all()
    }

    func duplicate(_ recipe: Recipe) throws {
        try requireIdle()
        let copy = try recipes.duplicate(recipe)
        try select(copy)
        library = try recipes.all()
    }

    func adaptedCopy() throws {
        try requireIdle()
        guard let recipe = selectedRecipe, let report = station.report,
              let copy = RecipeValidator.adaptedCopy(of: recipe, against: report, now: Date()).recipe else {
            throw RecipeStore.Failure.invalidDefinition
        }
        try save(copy)
    }

    func capture() async {
        guard let recipe = selectedRecipe else { notice = "Choose a recipe first."; return }
        if validation?.hasWarnings == true {
            notice = "Review the unsupported frames before capturing. Save an adapted copy or edit the recipe."
            return
        }
        let outcome = await station.captureTake(recipe: RecipeSnapshot(recipe)) { session in
            try self.runs.activate(sessionID: session.sessionId)
        }
        lastOutcome = outcome
        switch outcome {
        case .completed(_, let record): notice = "Take \(record.stationIndex) saved · \(record.brackets.reduce(0) { $0 + $1.frames.count }) frames"
        case .cancelled: notice = "Capture stopped. The incomplete Take was discarded; earlier Takes are safe."
        case .blocked(let message), .failed(_, let message): notice = message
        }
    }

    func finishRun() throws {
        try requireIdle()
        try runs.finish()
        station.closeSession()
        notice = "Run finished. Your next capture starts a new one."
        station.startFraming()
    }

    private func requireIdle() throws {
        guard !station.busy, !station.phase.isInStation else { throw ActiveRunStore.Failure.busy }
    }
}
