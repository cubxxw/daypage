import SwiftUI

struct TodayView: View {

    @StateObject private var viewModel = TodayViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                DSColor.background.ignoresSafeArea()
                VStack(spacing: 0) {
                    // MARK: Header
                    HStack {
                        Text("TODAY")
                            .headlineMDStyle()
                            .foregroundColor(DSColor.onSurface)
                        Spacer()
                        Text(Date(), format: .dateTime.month().day())
                            .monoLabelStyle(size: 11)
                            .foregroundColor(DSColor.onSurfaceVariant)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)

                    Divider()
                        .background(DSColor.outline)

                    // MARK: Timeline (75% of available space)
                    GeometryReader { geo in
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                // Daily Page entry card or compile prompt
                                Group {
                                    if viewModel.isDailyPageCompiled {
                                        DailyPageEntryCard(summary: viewModel.dailyPageSummary)
                                    } else {
                                        CompilePromptCard(
                                            memoCount: viewModel.memos.count,
                                            onCompile: { viewModel.compile() }
                                        )
                                    }
                                }
                                .padding(.horizontal, 20)

                                // Memo cards (reverse-chronological)
                                if viewModel.memos.isEmpty && !viewModel.isLoading {
                                    VStack(spacing: 8) {
                                        Spacer(minLength: 32)
                                        Text("今天还没有记录")
                                            .bodySMStyle()
                                            .foregroundColor(DSColor.onSurfaceVariant)
                                        Spacer(minLength: 32)
                                    }
                                    .frame(maxWidth: .infinity)
                                } else {
                                    ForEach(viewModel.memos) { memo in
                                        MemoCardView(memo: memo)
                                            .padding(.horizontal, 20)
                                    }
                                }

                                // Loading indicator
                                if viewModel.isLoading {
                                    HStack {
                                        Spacer()
                                        ProgressView()
                                            .tint(DSColor.onSurfaceVariant)
                                        Spacer()
                                    }
                                    .padding(.vertical, 20)
                                }

                                // Error message
                                if let error = viewModel.errorMessage {
                                    Text(error)
                                        .bodySMStyle()
                                        .foregroundColor(DSColor.error)
                                        .padding(.horizontal, 20)
                                }

                                Spacer(minLength: 16)
                            }
                            .padding(.top, 12)
                            .frame(minHeight: geo.size.height * 0.75)
                        }
                        .frame(maxHeight: geo.size.height)
                    }

                    Divider()
                        .background(DSColor.outline)

                    // MARK: Input bar placeholder (implemented in US-002)
                    HStack(spacing: 12) {
                        Text("记录想法…")
                            .bodyMDStyle()
                            .foregroundColor(DSColor.onSurfaceVariant)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(DSColor.surfaceContainerLow)
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                viewModel.load()
            }
        }
    }
}
