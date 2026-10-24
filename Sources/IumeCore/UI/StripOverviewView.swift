import SwiftUI
import AppKit

/// Interactive panoramic view displaying all apps and columns on the strip.
/// Supports smooth transitions, keyboard navigation, and live drag-to-reorder.
public struct StripOverviewView: View {
    @ObservedObject var controller: StripOverviewController
    
    @State private var draggedColumnId: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var hoveredColumnId: UUID?
    
    private let cardWidth: CGFloat = 290
    private let cardHeight: CGFloat = 185
    private let cardSpacing: CGFloat = 22
    
    public init(controller: StripOverviewController) {
        self.controller = controller
    }
    
    public var body: some View {
        ZStack {
            // Background Dim & Frosted Blur
            VisualEffectBlur(material: .fullScreenUI, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            Color.black.opacity(0.52)
                .ignoresSafeArea()
                .onTapGesture {
                    controller.dismiss(selectedColumnIndex: nil)
                }
            
            VStack(spacing: 32) {
                // Top Navigation & Instruction Header
                HStack(spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.split.3x1.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(Color(nsColor: .controlAccentColor))
                        
                        Text("Strip Overview")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    }
                    
                    Text("•")
                        .foregroundColor(.white.opacity(0.3))
                    
                    Text("\(controller.columns.count) \(controller.columns.count == 1 ? "column" : "columns") on strip")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                    
                    Spacer()
                    
                    // Keyboard hint badges
                    HStack(spacing: 8) {
                        hintBadge(key: "← →", label: "Navigate")
                        hintBadge(key: "↵", label: "Jump")
                        hintBadge(key: "ESC", label: "Close")
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 40)
                
                Spacer()
                
                // Panoramic Strip Cards
                ScrollView(.horizontal, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        HStack(spacing: cardSpacing) {
                            ForEach(Array(controller.columns.enumerated()), id: \.element.id) { index, col in
                                columnCard(for: col, at: index)
                                    .id(col.id)
                            }
                        }
                        .padding(.horizontal, 48)
                        .padding(.vertical, 24)
                        .onChange(of: controller.focusedColumnIndex) { newIndex in
                            if newIndex >= 0 && newIndex < controller.columns.count {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    proxy.scrollTo(controller.columns[newIndex].id, anchor: .center)
                                }
                            }
                        }
                    }
                }
                
                Spacer()
                
                // Bottom hint
                HStack(spacing: 6) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 13, weight: .medium))
                    Text("Drag any card horizontally to reorder the strip layout")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                }
                .foregroundColor(.white.opacity(0.5))
                .padding(.bottom, 36)
            }
        }
        .scaleEffect(controller.isPresented ? 1.0 : 0.96)
        .opacity(controller.isPresented ? 1.0 : 0.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: controller.isPresented)
    }
    
    // MARK: - Column Card
    
    @ViewBuilder
    private func columnCard(for col: OverviewColumnData, at index: Int) -> some View {
        let isBeingDragged = (draggedColumnId == col.id)
        let isFocused = (index == controller.focusedColumnIndex)
        let isHovered = (hoveredColumnId == col.id)
        let preview = col.previewItem
        
        VStack(alignment: .leading, spacing: 10) {
            // Column Meta Header
            HStack(spacing: 8) {
                if let icon = preview?.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 22, height: 22)
                }
                
                Text(preview?.appName ?? "Column \(index + 1)")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Spacer()
                
                if col.windowCount > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 9))
                        Text("\(col.windowCount)")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.18)))
                    .foregroundColor(.white.opacity(0.85))
                }
                
                Text("#\(index + 1)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            }
            .frame(width: cardWidth)
            
            // Window Snapshot Card Frame
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.55))
                
                if let snapshot = preview?.snapshot {
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(10)
                        .padding(6)
                } else {
                    // Fallback visual representation
                    VStack(spacing: 12) {
                        if let icon = preview?.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 54, height: 54)
                        }
                        Text(preview?.title ?? "Window Preview")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                }
                
                // Active focus overlay indicator
                if isFocused {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color(nsColor: .controlAccentColor))
                                    .frame(width: 6, height: 6)
                                Text("Active")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.75)))
                            .padding(10)
                        }
                    }
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isFocused ? Color(nsColor: .controlAccentColor) :
                            (isHovered ? Color.white.opacity(0.55) : Color.white.opacity(0.16)),
                        lineWidth: isFocused ? 2.5 : 1.0
                    )
            )
            .shadow(
                color: isFocused ? Color(nsColor: .controlAccentColor).opacity(0.45) : (isBeingDragged ? Color.black.opacity(0.6) : Color.black.opacity(0.25)),
                radius: isBeingDragged ? 22 : (isFocused ? 14 : 6)
            )
            
            // Window Title Subtext
            Text(preview?.title ?? "")
                .font(.system(size: 11.5, weight: .regular))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
                .frame(width: cardWidth, alignment: .leading)
        }
        .scaleEffect(isBeingDragged ? 1.06 : (isHovered ? 1.02 : 1.0))
        .offset(x: isBeingDragged ? dragTranslation : 0)
        .zIndex(isBeingDragged ? 99 : (isFocused ? 10 : 1))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { gesture in
                    draggedColumnId = col.id
                    dragTranslation = gesture.translation.width
                    
                    let slotUnit = cardWidth + cardSpacing
                    let shift = Int(round(gesture.translation.width / slotUnit))
                    let targetIndex = max(0, min(controller.columns.count - 1, index + shift))
                    
                    if targetIndex != index {
                        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.78)) {
                            controller.reorderColumnLocally(from: index, to: targetIndex)
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        dragTranslation = 0
                        draggedColumnId = nil
                    }
                    controller.commitReorderToWorkspace()
                }
        )
        .onHover { hovering in
            hoveredColumnId = hovering ? col.id : nil
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            controller.dismiss(selectedColumnIndex: index)
        }
    }
    
    // MARK: - Keyboard Hint Badge
    
    private func hintBadge(key: String, label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.18)))
            
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
        }
    }
}
