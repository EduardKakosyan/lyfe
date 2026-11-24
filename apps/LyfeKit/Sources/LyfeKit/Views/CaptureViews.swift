import PhotosUI
import SwiftUI

// MARK: Photo meal

/// A photo and one line: a meal of its own, or one part of a meal being
/// built. The model on the Spark estimates it afterwards; nothing waits
/// for it, and it works without a connection.
public struct PhotoMealView: View {
    let onLog: (String, Data?, MealSlot) async -> Void
    let onClose: () -> Void
    /// True when it is added to a meal, which has its own part of the day.
    private let asPart: Bool

    @State private var photo: Data?
    @State private var note = ""
    @State private var slot: MealSlot
    @State private var takingPhoto = false
    @State private var picked: PhotosPickerItem?
    @State private var problem: String?
    @State private var logging = false
    @FocusState private var noteFocused: Bool
    /// Whether the camera opens by itself when the screen does.
    private let opensCamera: Bool

    public init(
        start: MealSlot = .likely(at: Date()), photo: Data? = nil, note: String = "", opensCamera: Bool = true,
        asPart: Bool = false, onLog: @escaping (String, Data?, MealSlot) async -> Void, onClose: @escaping () -> Void
    ) {
        self.asPart = asPart
        self.opensCamera = opensCamera
        _slot = State(initialValue: start)
        _photo = State(initialValue: photo)
        _note = State(initialValue: note)
        self.onLog = onLog
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TopLine(left: asPart ? "← Meal" : "✕ Close", right: asPart ? "Photo · a part" : "Photo meal", onLeft: onClose)
                    shot
                    VStack(alignment: .leading, spacing: 10) {
                        Text("What it is · one line").posterLabel()
                        TextField(
                            "", text: $note, prompt: Text("STIR FRY, RICE, SOME OIL").foregroundStyle(Poster.ink.opacity(0.25)),
                            axis: .vertical
                        )
                        .font(.system(size: 26, weight: .heavy))
                        .tracking(-0.6)
                        .lineLimit(1...3)
                        .focused($noteFocused)
                        .submitLabel(.done)
                        .onChange(of: note) { _, text in
                            // The return key ends the line rather than starting another.
                            if text.contains("\n") {
                                note = text.replacingOccurrences(of: "\n", with: "")
                                noteFocused = false
                            }
                        }
                        .autocorrectionDisabled()
                        .accessibilityLabel("What the meal is")
                        if !asPart {
                            SlotPicker(slot: $slot)
                        }
                        Text(asPart ? CaptureText.photoPartHelp : CaptureText.photoHelp).posterLabel().opacity(0.55)
                        if let problem {
                            Text(problem).posterLabel()
                        }
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 14)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            Button {
                Task { await log() }
            } label: {
                BreathBar(
                    small: asPart ? "Estimated on the Spark while you add the rest" : "Counts for today's streak · estimated on the Spark",
                    big: asPart ? (logging ? "ADDING" : "ADD IT") : (logging ? "LOGGING" : "LOG IT"), mark: "→",
                    onDark: false)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!logging)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        #if os(iOS)
            .fullScreenCover(isPresented: $takingPhoto) {
                CameraPicker { shot in
                    takingPhoto = false
                    if let shot { use(shot) }
                    noteFocused = true
                }
                .ignoresSafeArea()
            }
            .onAppear {
                // Straight to the camera: the photo is the quick part.
                if opensCamera, photo == nil, CameraPicker.isAvailable { takingPhoto = true }
            }
        #endif
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { use(data) }
                picked = nil
                noteFocused = true
            }
        }
    }

    /// The photo, or the way to take one.
    private var shot: some View {
        ZStack(alignment: .bottomLeading) {
            // The picture fills the frame without setting its size.
            Rectangle().fill(Poster.ink).overlay {
                if let photo, let image = pictureImage(photo) {
                    image.resizable().scaledToFill()
                }
            }
            .clipped()
            if photo == nil {
                VStack(spacing: 6) {
                    Text("◉").font(.system(size: 44, weight: .heavy))
                    Text(cameraAvailable ? "Tap to take the photo" : "Choose a photo below").posterLabel()
                }
                .foregroundStyle(Poster.paper)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 0) {
                if cameraAvailable {
                    Button {
                        takingPhoto = true
                    } label: {
                        Text(photo == nil ? "Camera" : "Again").posterLabel().padding(10)
                    }
                }
                PhotosPicker(selection: $picked, matching: .images) {
                    Text("From photos").posterLabel().padding(10)
                }
                Spacer()
                if photo != nil {
                    Button {
                        photo = nil
                    } label: {
                        Text("No photo").posterLabel().padding(10)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Poster.paper)
            .background(Poster.ink)
        }
        .frame(height: 250)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture {
            if cameraAvailable, photo == nil { takingPhoto = true }
        }
        .overlay(alignment: .bottom) { PosterRule() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(photo == nil ? "No photo yet" : "The meal's photo")
    }

    private var cameraAvailable: Bool {
        #if os(iOS)
            CameraPicker.isAvailable
        #else
            false
        #endif
    }

    private func use(_ data: Data) {
        if let prepared = MealPhoto.prepare(data) {
            photo = prepared
            problem = nil
        } else {
            problem = "That picture could not be read."
        }
    }

    private func log() async {
        if photo == nil, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problem = "Take a photo, or say in a line what it was."
            return
        }
        logging = true
        defer { logging = false }
        noteFocused = false
        await onLog(note, photo, slot)
    }
}

// MARK: The estimate

/// A photo meal's estimate, as the drawn screen has it: the photo and the
/// line, the estimate with its range, the oil question when it matters,
/// and what the model saw, each portion open to correction.
public struct EstimateView: View {
    let entry: FoodDay.Entry
    let loadPhoto: () async -> Data?
    /// The photo drawn as a Poster illustration, once it has been.
    let loadIllustration: () async -> Data?
    let onCorrect: (LyfeAPI.EstimateChange) async -> String?
    /// Fetches the day again, to follow an estimate still being made.
    let onReload: () async -> Void
    let onTakeBack: () async -> String?
    let onClose: () -> Void
    /// True for a part of a meal, which it is taken out of rather than
    /// off the day.
    private let inMeal: Bool

    @State private var photo: Data?
    @State private var drawing: Data?
    /// The photo shown in place of its drawing, after a tap.
    @State private var showingPhoto = false
    @State private var changing: Int?
    @State private var grams = ""
    @State private var typing = false
    @State private var typedKcal = ""
    @State private var typedProtein = ""
    @State private var note: String?
    @State private var busy = false
    @State private var confirmingTakeBack = false

    public init(
        entry: FoodDay.Entry, inMeal: Bool = false, loadPhoto: @escaping () async -> Data?,
        loadIllustration: @escaping () async -> Data? = { nil },
        onCorrect: @escaping (LyfeAPI.EstimateChange) async -> String?, onReload: @escaping () async -> Void,
        onTakeBack: @escaping () async -> String?, onClose: @escaping () -> Void
    ) {
        self.inMeal = inMeal
        self.entry = entry
        self.loadPhoto = loadPhoto
        self.loadIllustration = loadIllustration
        self.onCorrect = onCorrect
        self.onReload = onReload
        self.onTakeBack = onTakeBack
        self.onClose = onClose
    }

    private var detail: FoodDay.PhotoDetail? { entry.photo }
    private var awaitingDrawing: Bool {
        entry.figures != .estimating && detail?.hasPhoto == true && detail?.illustrated != true
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TopLine(
                        left: inMeal ? "← Meal" : "← Food",
                        right: inMeal ? "Photo · a part" : "Photo meal · \(FoodText.slotName(entry.slot))", onLeft: onClose)
                    shot
                    estimate
                    PosterRule()
                    if let note {
                        NoticeRow(text: note)
                        PosterRule(thickness: 1.5)
                    }
                    if detail?.oilAsked == true, entry.isKnown, detail?.typed != true {
                        oil
                        PosterRule()
                    }
                    if detail?.typed != true {
                        ForEach(Array((detail?.items ?? []).enumerated()), id: \.offset) { index, item in
                            itemRow(index, item)
                            PosterRule(thickness: 1.5)
                        }
                    }
                    typeInstead
                    PosterRule(thickness: 1.5)
                    Button {
                        confirmingTakeBack = true
                    } label: {
                        Text(inMeal ? "Take it out of the meal" : "Take it off today").posterLabel().opacity(0.55)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            Button(action: onClose) {
                BreathBar(
                    small: inMeal ? "Counted with its meal" : "Counts for today's streak", big: "DONE", mark: "→",
                    onDark: false)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .task { photo = await loadPhoto() }
        // Again when the photo has been drawn again in a new look.
        .task(id: entry.illustration) {
            if entry.illustration != nil { drawing = await loadIllustration() }
        }
        // Estimated and not drawn yet: look again now and then for a while,
        // so the drawing takes the photo's place without leaving the
        // screen. Loading the image model can take a couple of minutes.
        .task(id: awaitingDrawing) {
            var looks = 0
            while awaitingDrawing, looks < 20, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await onReload()
                looks += 1
            }
        }
        // While the model is at it, look again every few seconds.
        .task(id: entry.figures) {
            while entry.figures == .estimating, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await onReload()
            }
        }
        .confirmationDialog(
            inMeal ? "Take \(entry.name) out of the meal?" : "Take \(entry.name) off today?",
            isPresented: $confirmingTakeBack, titleVisibility: .visible
        ) {
            Button(inMeal ? "Take it out" : "Take it off", role: .destructive) {
                Task {
                    note = await onTakeBack()
                    if note == nil { onClose() }
                }
            }
        }
    }

    /// The illustration once drawn, else the photo; a tap swaps them.
    private var shot: some View {
        let drawn = drawing.flatMap(pictureImage)
        return ZStack(alignment: .bottomLeading) {
            if let drawn, !showingPhoto {
                // Drawn on the paper colour, so it needs no frame.
                Rectangle().fill(Poster.paper).overlay {
                    drawn.resizable().interpolation(.medium).scaledToFit().padding(.top, 8).padding(.bottom, 28)
                }
            } else {
                // The picture fills the frame without setting its size, so
                // the line stays at the bottom of what is seen.
                Rectangle().fill(Poster.ink).overlay {
                    if let photo, let image = pictureImage(photo) {
                        image.resizable().scaledToFill()
                    }
                }
                .clipped()
            }
            if let line = detail?.note, !line.isEmpty {
                Text("“\(line)”")
                    .posterLabel()
                    .lineLimit(2)
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Poster.paper)
                    .background(Poster.ink)
            }
        }
        .frame(height: detail?.hasPhoto == false ? 70 : 210)
        .clipped()
        .overlay(alignment: .topTrailing) {
            if drawn != nil {
                Text(showingPhoto ? "Drawing" : "Photo")
                    .posterLabel()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Poster.paper)
                    .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 1.5))
                    .padding(10)
            }
        }
        .overlay(alignment: .bottom) { PosterRule() }
        .contentShape(Rectangle())
        .onTapGesture {
            if drawn != nil { showingPhoto.toggle() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            drawn != nil && !showingPhoto
                ? "Drawing of \(detail?.note ?? entry.name)" : (detail?.note ?? entry.name))
        .accessibilityHint(drawn == nil ? "" : showingPhoto ? "Shows the drawing" : "Shows the photo")
        .accessibilityAddTraits(drawn == nil ? [] : .isButton)
    }

    /// The giant figure and, beside it, the range and the protein.
    private var estimate: some View {
        let look = CaptureText.estimate(entry)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(look.label).posterLabel()
                    Text(Poster.tight(look.giant, by: -5))
                        .font(.system(size: 96, weight: .heavy))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(.numericText())
                        .padding(.bottom, -8)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(look.rangeLabel).posterLabel()
                    Text(look.range).font(.system(size: 17, weight: .heavy)).monospacedDigit()
                    Text("Protein").posterLabel().padding(.top, 6)
                    Text(look.protein).font(.system(size: 17, weight: .heavy)).monospacedDigit()
                }
                .padding(.bottom, 4)
            }
            if let words = look.words {
                Text(words).posterLabel().padding(.top, 4)
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(.snappy, value: entry.kcal)
    }

    /// Asked only for a fried, sauced or restaurant meal.
    private var oil: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("How much oil or sauce?").posterLabel()
                Spacer()
                if detail?.oil == nil {
                    Text("Counted as some until you say").posterLabel().opacity(0.55)
                }
            }
            HStack(spacing: 6) {
                ForEach(Oil.allCases, id: \.self) { choice in
                    let chosen = detail?.oil == choice
                    let assumed = detail?.oil == nil && choice == .aBit
                    Button {
                        Task { await correct(.portions(grams: nil, oil: choice)) }
                    } label: {
                        Text(CaptureText.oilName(choice))
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(0.7)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(chosen ? Poster.paper : Poster.ink)
                            .background {
                                if chosen {
                                    Poster.ink
                                } else if assumed {
                                    Stripes(spacing: 3).foregroundStyle(Poster.ink.opacity(0.18))
                                }
                            }
                            .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 12)
        .background(Poster.yellow)
        .allowsHitTesting(!busy)
    }

    @ViewBuilder
    private func itemRow(_ index: Int, _ item: FoodDay.EstimateItem) -> some View {
        if changing == index {
            HStack(spacing: 8) {
                Text(item.name).font(.system(size: 15, weight: .heavy)).textCase(.uppercase).lineLimit(1)
                Spacer(minLength: 4)
                TextField("", text: $grams, prompt: Text(FoodText.plain(item.grams)))
                    .font(.system(size: 17, weight: .heavy))
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    #if os(iOS)
                        .keyboardType(.decimalPad)
                    #endif
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                    .accessibilityLabel("Grams of \(item.name)")
                Text("G").posterLabel()
                Button {
                    Task { await keepGrams(index) }
                } label: {
                    Text("Keep")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(0.7)
                        .textCase(.uppercase)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .foregroundStyle(Poster.yellow)
                        .background(Poster.ink)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 7)
            .background(Poster.yellow)
        } else {
            Button {
                changing = index
                grams = FoodText.plain(item.grams)
                note = nil
            } label: {
                FoodRow(row: CaptureText.itemRow(index, item))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Changes its grams")
        }
    }

    /// Figures typed instead of the model's: for a meal it could not
    /// estimate, or one with a menu that says.
    @ViewBuilder
    private var typeInstead: some View {
        if typing || entry.figures == .failed {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.figures == .failed ? "Type what it came to" : "Type it instead").posterLabel()
                HStack(alignment: .bottom, spacing: 6) {
                    LabeledField(label: "kcal", text: $typedKcal, prompt: "650", numeric: true)
                    LabeledField(label: "Protein · g", text: $typedProtein, prompt: "40", numeric: true)
                    Button {
                        Task { await keepTyped() }
                    } label: {
                        Text("Keep")
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(0.7)
                            .textCase(.uppercase)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .foregroundStyle(Poster.yellow)
                            .background(Poster.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 12)
            .background(Poster.yellow)
        } else {
            Button {
                typing = true
                typedKcal = entry.isKnown ? String(entry.kcal) : ""
                typedProtein = entry.isKnown ? FoodText.grams(entry.proteinG) : ""
            } label: {
                StripRow(left: detail?.typed == true ? "Typed by you" : "Know the figures?", right: "Type them →")
            }
            .buttonStyle(.plain)
        }
    }

    private func keepGrams(_ index: Int) async {
        guard let items = detail?.items, items.indices.contains(index) else { return }
        switch FoodTyping.number(grams) {
        case .some(let value) where value <= 3000:
            var all = items.map(\.grams)
            all[index] = value
            changing = nil
            await correct(.portions(grams: all, oil: nil))
        default:
            note = "Type its grams, 0 to 3000. 0 takes it out."
        }
    }

    private func keepTyped() async {
        switch FoodTyping.mealFigures(kcal: typedKcal, protein: typedProtein) {
        case .success(let figures):
            typing = false
            await correct(.typed(kcal: figures.kcal, proteinG: figures.proteinG))
        case .failure(let slip):
            note = slip.message + "."
        }
    }

    private func correct(_ change: LyfeAPI.EstimateChange) async {
        busy = true
        defer { busy = false }
        note = await onCorrect(change)
    }
}

/// A photo meal still on this phone: logged, not sent, so not estimated.
struct WaitingPhotoView: View {
    let capture: FoodCapture
    let loadPhoto: () async -> Data?
    let onClose: () -> Void

    @State private var photo: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TopLine(left: "← Food", right: "Photo meal · \(FoodText.slotName(capture.slot))", onLeft: onClose)
            if let photo, let image = pictureImage(photo) {
                image.resizable().scaledToFill().frame(height: 210).clipped()
                PosterRule()
            }
            Text("…").font(.system(size: 96, weight: .heavy)).padding(.horizontal, Poster.margin)
            Text(CaptureText.waitingHelp).posterLabel().padding(.horizontal, Poster.margin)
            Spacer()
            Button(action: onClose) {
                BreathBar(small: "Counts for today's streak", big: "DONE", mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
        .task { photo = await loadPhoto() }
    }
}

// MARK: Barcode

/// Packaged food: scan its barcode, say how much was eaten. The label's
/// figures come from the food database, or are typed once from the
/// packet when the database does not have it. A meal of its own, or one
/// part of a meal being built.
public struct ScanView: View {
    let lookUp: (String) async -> AppModel.ProductLookup
    let onSetLabel: (Product) async -> String?
    let onLog: (String, Double, MealSlot, Product?) async -> Void
    let onClose: () -> Void
    /// True when it is added to a meal, which has its own part of the day.
    private let asPart: Bool

    @State private var code: String?
    @State private var typedCode = ""
    @State private var lookup: AppModel.ProductLookup?
    @State private var grams = ""
    @State private var slot: MealSlot
    @State private var label = LabelForm()
    @State private var note: String?
    @State private var busy = false

    public init(
        start: MealSlot = .likely(at: Date()), code: String? = nil, lookup: AppModel.ProductLookup? = nil,
        asPart: Bool = false, lookUp: @escaping (String) async -> AppModel.ProductLookup,
        onSetLabel: @escaping (Product) async -> String?,
        onLog: @escaping (String, Double, MealSlot, Product?) async -> Void, onClose: @escaping () -> Void
    ) {
        self.asPart = asPart
        _slot = State(initialValue: start)
        _code = State(initialValue: code)
        _lookup = State(initialValue: lookup)
        if case .found(let product) = lookup, let serving = product.servingG {
            _grams = State(initialValue: FoodText.plain(serving))
        }
        self.lookUp = lookUp
        self.onSetLabel = onSetLabel
        self.onLog = onLog
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TopLine(
                        left: asPart ? "← Meal" : "✕ Close", right: code.map { "Barcode \($0)" } ?? "Scan a barcode",
                        onLeft: onClose)
                    if let code {
                        product(code)
                    } else {
                        scanner
                    }
                    if let note {
                        PosterRule(thickness: 1.5)
                        NoticeRow(text: note)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            if code != nil {
                let bar = CaptureText.scanBar(lookup: lookup, grams: FoodTyping.number(grams), busy: busy, adding: asPart)
                Button {
                    Task { await log() }
                } label: {
                    BreathBar(small: bar.small, big: bar.big, mark: "→", onDark: false)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(!busy && lookup != nil)
            }
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
    }

    /// The live reader, and the number typed by hand for when it cannot read.
    private var scanner: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(Poster.ink)
                #if os(iOS)
                    if BarcodeScanner.isAvailable {
                        BarcodeScanner { found in Task { await use(found) } }
                    } else {
                        Text("No camera reader here · type the number").posterLabel().foregroundStyle(Poster.paper)
                    }
                #else
                    Text("Type the number").posterLabel().foregroundStyle(Poster.paper)
                #endif
            }
            .frame(height: 300)
            .clipped()
            PosterRule()
            VStack(alignment: .leading, spacing: 8) {
                Text("Or type the number under the bars").posterLabel()
                HStack(spacing: 6) {
                    TextField("", text: $typedCode, prompt: Text("0 64200 11589 6").foregroundStyle(Poster.ink.opacity(0.3)))
                        .font(.system(size: 20, weight: .heavy))
                        .monospacedDigit()
                        #if os(iOS)
                            .keyboardType(.numberPad)
                        #endif
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(Poster.paper)
                        .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                        .accessibilityLabel("Barcode number")
                    Button {
                        if let found = FoodTyping.barcode(typedCode) {
                            Task { await use(found) }
                        } else {
                            note = "A barcode is 8 to 14 digits."
                        }
                    } label: {
                        Text("Look up")
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(0.7)
                            .textCase(.uppercase)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                            .foregroundStyle(Poster.yellow)
                            .background(Poster.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Poster.margin)
            .padding(.vertical, 12)
            .background(Poster.yellow)
        }
    }

    /// What the code is, how much was eaten, and when.
    @ViewBuilder
    private func product(_ code: String) -> some View {
        let look = CaptureText.product(lookup)
        VStack(alignment: .leading, spacing: 6) {
            Text(look.heading).posterHeading(30).lineLimit(2).minimumScaleFactor(0.6)
            Text(look.detail).posterLabel()
            Button {
                self.code = nil
                lookup = nil
                typedCode = ""
                note = nil
            } label: {
                Text("Scan another").posterLabel().opacity(0.55).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 12)
        PosterRule()
        if lookup == .notFound {
            LabelFormView(form: $label)
            PosterRule()
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("How much you ate").posterLabel()
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                TextField("", text: $grams, prompt: Text("0").foregroundStyle(Poster.ink.opacity(0.2)))
                    .font(.system(size: 64, weight: .heavy))
                    .tracking(-3)
                    .monospacedDigit()
                    .fixedSize()
                    #if os(iOS)
                        .keyboardType(.decimalPad)
                    #endif
                    .accessibilityLabel("Grams eaten")
                Text("g").posterHeading(26)
            }
            if case .found(let product) = lookup, let serving = product.servingG {
                HStack(spacing: 6) {
                    ForEach([0.5, 1, 2], id: \.self) { servings in
                        Button {
                            grams = FoodText.plain(serving * servings)
                        } label: {
                            Text(CaptureText.servings(servings, of: serving))
                                .font(.system(size: 11, weight: .heavy))
                                .tracking(0.6)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .padding(.horizontal, 5)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !asPart {
                SlotPicker(slot: $slot)
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 12)
    }

    private func use(_ found: String) async {
        code = found
        note = nil
        lookup = nil
        let result = await lookUp(found)
        lookup = result
        if case .found(let product) = result, let serving = product.servingG, grams.isEmpty {
            grams = FoodText.plain(serving)
        }
    }

    private func log() async {
        guard let code, let lookup else { return }
        let eaten: Double
        switch FoodTyping.grams(grams) {
        case .success(let value): eaten = value
        case .failure(let slip):
            note = slip.message + "."
            return
        }
        busy = true
        defer { busy = false }
        switch lookup {
        case .found(let product):
            await onLog(code, eaten, slot, product)
        case .offline:
            await onLog(code, eaten, slot, nil)
        case .notFound:
            switch label.product(code: code) {
            case .failure(let slip):
                note = slip.message + "."
            case .success(let product):
                // The label first, so the meal arrives with its figures.
                if let problem = await onSetLabel(product) {
                    note = problem
                    return
                }
                await onLog(code, eaten, slot, product)
            }
        }
    }
}

/// The label of a code lyfe does not know, typed once for a meal already
/// logged with it. Every meal waiting for it gets its figures.
public struct LabelView: View {
    let code: String
    let onSave: (Product) async -> String?
    let onClose: () -> Void

    @State private var form = LabelForm()
    @State private var note: String?
    @State private var saving = false

    public init(code: String, onSave: @escaping (Product) async -> String?, onClose: @escaping () -> Void) {
        self.code = code
        self.onSave = onSave
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TopLine(left: "✕ Close", right: "Barcode \(code)", onLeft: onClose)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not in the food database").posterHeading(28)
                        Text("Type it once from the packet. Every meal with this code gets these figures.").posterLabel()
                    }
                    .padding(.horizontal, Poster.margin)
                    .padding(.vertical, 12)
                    PosterRule()
                    LabelFormView(form: $form)
                    if let note {
                        PosterRule(thickness: 1.5)
                        NoticeRow(text: note)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            Button {
                Task { await save() }
            } label: {
                BreathBar(small: "Measured · from the label", big: saving ? "SAVING" : "SAVE THE LABEL", mark: "→", onDark: false)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(!saving)
        }
        .foregroundStyle(Poster.ink)
        .background(Poster.paper.ignoresSafeArea())
    }

    private func save() async {
        switch form.product(code: code) {
        case .failure(let slip):
            note = slip.message + "."
        case .success(let product):
            saving = true
            defer { saving = false }
            note = await onSave(product)
        }
    }
}

/// What is typed from a label.
struct LabelForm: Equatable {
    var name = ""
    var kcal = ""
    var protein = ""
    var serving = ""

    func product(code: String) -> Result<Product, FoodSlip> {
        FoodTyping.label(code: code, name: name, kcal: kcal, protein: protein, serving: serving)
    }
}

struct LabelFormView: View {
    @Binding var form: LabelForm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("From the label").posterLabel()
            LabeledField(label: "Product", text: $form.name, prompt: "SKYR CUP")
            HStack(alignment: .bottom, spacing: 6) {
                LabeledField(label: "kcal per 100 g", text: $form.kcal, prompt: "63", numeric: true)
                LabeledField(label: "Protein per 100 g", text: $form.protein, prompt: "11", numeric: true)
                LabeledField(label: "Serving · g", text: $form.serving, prompt: "175", numeric: true)
            }
        }
        .padding(.horizontal, Poster.margin)
        .padding(.vertical, 12)
        .background(Poster.yellow)
    }
}

// MARK: Parts

/// The line at the top of a full screen: the way out, and what this is.
struct TopLine: View {
    var left: String
    var right: String
    var onLeft: () -> Void

    var body: some View {
        HStack {
            Button(action: onLeft) {
                Text(left).posterLabel().padding(.vertical, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(right).posterLabel().lineLimit(1)
        }
        .padding(.horizontal, Poster.margin)
    }
}

/// Breakfast, lunch, dinner or snack.
struct SlotPicker: View {
    @Binding var slot: MealSlot

    var body: some View {
        HStack(spacing: 6) {
            ForEach(MealSlot.allCases, id: \.self) { choice in
                Button {
                    slot = choice
                } label: {
                    Text(FoodText.slotName(choice))
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(slot == choice ? Poster.paper : Poster.ink)
                        .background(slot == choice ? Poster.ink : .clear)
                        .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(slot == choice ? .isSelected : [])
            }
        }
    }
}

/// A small label over a boxed field, as in the meal editor.
struct LabeledField: View {
    var label: String
    @Binding var text: String
    var prompt: String
    var numeric = false
    /// What the return key does, when it leads on to another field.
    var onSubmit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).posterLabel().lineLimit(1).minimumScaleFactor(0.7)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Poster.ink.opacity(0.3)))
                .font(.system(size: 17, weight: .heavy))
                .monospacedDigit()
                .submitLabel(onSubmit == nil ? .done : .next)
                .onSubmit { onSubmit?() }
                #if os(iOS)
                    .keyboardType(numeric ? .decimalPad : .default)
                    .textInputAutocapitalization(.words)
                #endif
                .autocorrectionDisabled()
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Poster.paper)
                .overlay(Rectangle().strokeBorder(Poster.ink, lineWidth: 2.5))
                .accessibilityLabel(label)
        }
    }
}

// MARK: Words

/// The words on the photo and barcode screens. Plain functions, so they
/// can be checked without a screen.
public enum CaptureText {
    static let photoHelp =
        "The model on the Spark estimates it, give or take a third. Without a connection it is kept here and estimated once sent."

    static let photoPartHelp =
        "The model on the Spark estimates it, give or take a third, while you add the rest. It shows in the meal when it answers."

    static let waitingHelp =
        "Logged on this phone. It is sent, and estimated, once the server can be reached. It already counts for today."

    static func oilName(_ oil: Oil) -> String {
        switch oil {
        case .nothing: "NONE"
        case .aBit: "SOME"
        case .aLot: "A LOT"
        }
    }

    struct EstimateLook: Equatable {
        var label: String
        var giant: String
        var rangeLabel: String
        var range: String
        var protein: String
        /// What is happening, when the figure is not the estimate yet.
        var words: String?
    }

    /// The top of the estimate screen.
    static func estimate(_ entry: FoodDay.Entry) -> EstimateLook {
        let detail = entry.photo
        switch entry.figures ?? .known {
        case .estimating:
            return EstimateLook(
                label: "Estimate · kcal", giant: "…", rangeLabel: "Range", range: "—", protein: "—",
                words: detail?.problem
                    ?? "Being estimated on the Spark: seconds, or a couple of minutes if the model has to load first.")
        case .failed, .needsLabel:
            return EstimateLook(
                label: "No estimate", giant: "?", rangeLabel: "Range", range: "—", protein: "—",
                words: (detail?.problem.map { $0 + " " } ?? "") + "Type what it came to below.")
        case .known where detail?.typed == true:
            return EstimateLook(
                label: "Typed · kcal", giant: FoodText.kcal(entry.kcal), rangeLabel: "Range", range: "yours",
                protein: "\(FoodText.grams(entry.proteinG)) G")
        case .known:
            let range = entry.kcalLow.flatMap { low in entry.kcalHigh.map { "\(FoodText.kcal(low))–\(FoodText.kcal($0))" } }
            let oil = detail.map { $0.oilKcal > 0 ? "Includes \($0.oilKcal) kcal of oil or sauce" : nil } ?? nil
            return EstimateLook(
                label: "Estimate · kcal", giant: FoodText.kcal(entry.kcal), rangeLabel: "Range", range: range ?? "—",
                protein: "\(FoodText.grams(entry.proteinG)) G", words: oil)
        }
    }

    /// One thing the model saw, with the grams that count.
    static func itemRow(_ index: Int, _ item: FoodDay.EstimateItem) -> FoodText.Row {
        let changed = abs(item.grams - item.gramsSeen) > 0.01
        let label =
            item.grams == 0
            ? "TAKEN OUT · TAP TO PUT BACK"
            : changed
                ? "\(FoodText.kcal(item.kcal)) KCAL · YOU SAID · MODEL \(FoodText.plain(item.gramsSeen)) G"
                : "\(FoodText.kcal(item.kcal)) KCAL · \(FoodText.grams(item.proteinG)) G PROTEIN · TAP TO CHANGE"
        return FoodText.Row(
            id: "item-\(index)", entry: nil, mark: changed ? .solid : .striped, title: item.name, label: label,
            value: "\(FoodText.plain(item.grams)) G", dim: item.grams == 0)
    }

    /// "1 SERVING · 60 G"
    static func servings(_ count: Double, of serving: Double) -> String {
        let name =
            switch count {
            case 0.5: "½ SERVING"
            case 1: "1 SERVING"
            default: "\(FoodText.plain(count)) SERVINGS"
            }
        return "\(name) · \(FoodText.plain(serving * count)) G"
    }

    /// What lyfe knows of a scanned code.
    static func product(_ lookup: AppModel.ProductLookup?) -> (heading: String, detail: String) {
        switch lookup {
        case nil:
            return ("Looking it up…", "")
        case .found(let product):
            let source = product.origin == "label" ? "YOUR LABEL" : "FOOD DATABASE"
            return (
                product.name,
                "\(source) · \(FoodText.plain(product.kcalPer100g)) KCAL · \(FoodText.plain(product.proteinPer100g)) G PROTEIN PER 100 G"
            )
        case .notFound:
            return ("Not in the food database", "TYPE IT ONCE FROM THE LABEL · REMEMBERED AFTER THAT")
        case .offline:
            return ("No connection", "LOGGED NOW · LOOKED UP ONCE SENT")
        }
    }

    /// The scan screen's bar: what the grams come to, once known.
    static func scanBar(lookup: AppModel.ProductLookup?, grams: Double?, busy: Bool, adding: Bool = false) -> (
        small: String, big: String
    ) {
        let big = adding ? (busy ? "ADDING" : "ADD IT") : (busy ? "LOGGING" : "LOG IT")
        guard let grams, grams > 0 else { return ("TYPE THE GRAMS EATEN", big) }
        switch lookup {
        case .found(let product):
            let amount = product.amount(grams: grams)
            return ("MEASURED · \(FoodText.kcal(amount.kcal)) KCAL · \(FoodText.grams(amount.proteinG)) G PROTEIN", big)
        case .notFound:
            return ("SAVES THE LABEL, THEN \(adding ? "ADDS" : "LOGS") \(FoodText.plain(grams)) G", big)
        case .offline:
            return ("\(FoodText.plain(grams)) G · COUNTED ONCE SENT", big)
        case nil:
            return ("LOOKING IT UP", big)
        }
    }
}
