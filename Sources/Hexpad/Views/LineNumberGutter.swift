import AppKit
import HexpadKit

class LineNumberGutter: NSRulerView {
    
    private var clickHandler: ((NSPoint) -> Void)?
    
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = scrollView?.documentView
    }
    
    required init(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    func setClickHandler(_ handler: ((NSPoint) -> Void)?) {
        clickHandler = handler
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let textView = scrollView?.documentView as? NSTextView else { return }
        
        let text = textView.string
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let lineHeight = font.pointSize * 1.5
        
        var lineNum = 1
        var yPosition = bounds.height
        
        while yPosition > 0 {
            let charIndex = charIndexForYPosition(textView, y: yPosition)
            let lineForY = lineNumberAtCharIndex(text, charIndex: charIndex)
            
            if lineNum != lineForY {
                lineNum = lineForY
                yPosition -= lineHeight
                continue
            }
            
            let lineStr = "\(lineNum)"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.darkGray
            ]
            let size = lineStr.size(withAttributes: attributes)
            let x = (bounds.width - size.width) / 2
            let y = yPosition - size.height
            
            lineStr.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
            
            let tickStart = NSPoint(x: bounds.width - 5, y: yPosition)
            let tickEnd = NSPoint(x: bounds.width, y: yPosition)
            NSColor.lightGray.setStroke()
            let tick = NSBezierPath()
            tick.move(to: tickStart)
            tick.line(to: tickEnd)
            tick.lineWidth = 1
            tick.stroke()
            
            lineNum += 1
            yPosition -= lineHeight
        }
    }
    
    private func charIndexForYPosition(_ textView: NSTextView, y: CGFloat) -> Int {
        guard let layoutManager = textView.textStorage?.layoutManagers.first as? NSLayoutManager,
              let textContainer = textView.textContainer else { return 0 }
        var fraction: CGFloat = 0
        return layoutManager.characterIndex(for: NSPoint(x: 0, y: y), in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
    }
    
    private func lineNumberAtCharIndex(_ text: String, charIndex: Int) -> Int {
        guard charIndex > 0 else { return 1 }
        let textNSString = text as NSString
        var lineNum = 1
        var loc = 0
        while loc < charIndex {
            let lineRange = textNSString.lineRange(for: NSRange(location: loc, length: 0))
            if lineRange.location == NSNotFound { break }
            lineNum += 1
            loc = lineRange.upperBound
        }
        return lineNum
    }
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        clickHandler?(point)
    }
}
