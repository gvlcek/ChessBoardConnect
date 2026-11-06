import SwiftUI
import ChessBoardConnect

struct BoardPositionView: View {
    let position: BoardPosition
    private let glyphs: [Character: String] = ["K":"♔", "Q":"♕", "R":"♖", "B":"♗", "N":"♘", "P":"♙", "k":"♚", "q":"♛", "r":"♜", "b":"♝", "n":"♞", "p":"♟"]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), spacing: 0) {
            ForEach(0..<64, id: \.self) { index in
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill((index / 8 + index % 8).isMultiple(of: 2) ? Color(red: 0.9, green: 0.86, blue: 0.76) : Color(red: 0.43, green: 0.54, blue: 0.44))
                    Text(glyphs[position.squares[index]] ?? "").font(.system(size: 29)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(BoardPosition.name(index)).font(.system(size: 8)).foregroundStyle(.black.opacity(0.65)).padding(2)
                }.aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel("\(BoardPosition.name(index)): \(String(position.squares[index]))")
            }
        }.clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
