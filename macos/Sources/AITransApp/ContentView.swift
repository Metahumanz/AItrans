import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("AItrans")
                .font(.largeTitle.weight(.semibold))
            Text("原生客户端骨架（M1 开发中）")
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 720, minHeight: 480)
        .padding(40)
    }
}
