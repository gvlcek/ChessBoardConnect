import SwiftUI

struct GuidanceLabSection: View {
    @ObservedObject var model: ConnectionLabViewModel

    var body: some View {
        Section("Unified move guidance") {
            Text("Use the same controls with either board. Arrange the initial pieces, prepare the session, then guide one move at a time.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Guidance", value: model.guidanceDescription)
            VStack(alignment: .leading, spacing: 4) {
                Text("Initial full FEN").font(.caption).foregroundStyle(.secondary)
                TextField("Initial full FEN", text: $model.fen, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Button("Prepare guidance session") { model.prepareGuidance() }.disabled(!model.canPrepareGuidance)
            MoveInputFields(from: $model.moveFrom, to: $model.moveTo, promotion: $model.promotion)
            VStack(alignment: .leading, spacing: 4) {
                Text("Expected position after move (FEN)").font(.caption).foregroundStyle(.secondary)
                TextField("Expected position after move (FEN)", text: $model.expectedFEN, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Button("Guide move") { model.guideMove() }.disabled(!model.canGuideMove)
            if !model.guidanceDifferences.isEmpty {
                LabeledContent("Differing squares", value: model.guidanceDifferenceDescription)
            }
            Button("Cancel guidance", role: .destructive) { model.cancelGuidance() }.disabled(!model.guidanceState.isActive)
            Text("Completion requires an exact stable position or a matching reported move, depending on board capabilities. A command acknowledgment alone does not complete a move. Cancelling move-protocol guidance disconnects the board.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MoveInputFields: View {
    @Binding var from: String
    @Binding var to: String
    @Binding var promotion: String

    var body: some View {
        LabeledContent("From") {
            TextField("From", text: $from).textInputAutocapitalization(.never).autocorrectionDisabled().multilineTextAlignment(.trailing)
        }
        LabeledContent("To") {
            TextField("To", text: $to).textInputAutocapitalization(.never).autocorrectionDisabled().multilineTextAlignment(.trailing)
        }
        Picker("Promotion", selection: $promotion) {
            Text("None").tag("")
            Text("Queen").tag("q")
            Text("Rook").tag("r")
            Text("Bishop").tag("b")
            Text("Knight").tag("n")
        }
    }
}
