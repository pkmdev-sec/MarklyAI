import AppKit

final class ListFlowLayout: NSCollectionViewFlowLayout {
    private let metrics: ListMetrics
    private var lastKnownWidth: CGFloat = 0

    init(metrics: ListMetrics) {
        self.metrics = metrics
        super.init()
        scrollDirection = .vertical
        minimumLineSpacing = metrics.verticalGap
        minimumInteritemSpacing = 0
        sectionInset = NSEdgeInsets(top: metrics.verticalGap, left: 0, bottom: metrics.verticalGap, right: 0)
    }

    required init?(coder: NSCoder) {
        self.metrics = ListMetrics()
        super.init(coder: coder)
        scrollDirection = .vertical
        minimumLineSpacing = metrics.verticalGap
        minimumInteritemSpacing = 0
        sectionInset = NSEdgeInsets(top: metrics.verticalGap, left: 0, bottom: metrics.verticalGap, right: 0)
    }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let currentWidth = collectionView.bounds.size.width
        if abs(currentWidth - lastKnownWidth) > 0.5 {
            lastKnownWidth = currentWidth
            updateItemSize(for: collectionView.bounds.size)
        }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        let newWidth = newBounds.size.width
        if abs(newWidth - lastKnownWidth) > 0.5 {
            lastKnownWidth = newWidth
            updateItemSize(for: newBounds.size)
            return true
        }
        return false
    }

    private func updateItemSize(for size: NSSize) {
        let scrollInsets = collectionView?.enclosingScrollView?.contentInsets ?? NSEdgeInsetsZero
        let availableWidth = size.width
            - sectionInset.left - sectionInset.right
            - scrollInsets.left - scrollInsets.right
        if availableWidth <= 1 {
            return
        }
        let width = max(1, availableWidth - 1)
        itemSize = NSSize(width: width, height: metrics.rowHeight)
    }
}
