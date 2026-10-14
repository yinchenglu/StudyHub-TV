package com.studyvault.tv.ui

import android.content.Context
import android.graphics.Matrix
import android.graphics.PointF
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import androidx.appcompat.widget.AppCompatImageView

/**
 * 可缩放/拖动的图片控件。
 * - 触屏：双指缩放、单指拖动
 * - 遥控：调用 zoomIn() / zoomOut() 由菜单键触发
 */
class ZoomImageView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : AppCompatImageView(context, attrs, defStyleAttr) {

    private val matrix = Matrix()
    private val lastTouch = PointF()
    private var currentScale = 1f

    private val scaleDetector = ScaleGestureDetector(
        context,
        object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                var factor = detector.scaleFactor
                val target = currentScale * factor
                when {
                    target < MIN_SCALE -> factor = MIN_SCALE / currentScale
                    target > MAX_SCALE -> factor = MAX_SCALE / currentScale
                }
                currentScale *= factor
                matrix.postScale(factor, factor, detector.focusX, detector.focusY)
                imageMatrix = matrix
                return true
            }
        }
    )

    init {
        scaleType = ScaleType.MATRIX
    }

    fun resetZoom() {
        currentScale = 1f
        matrix.reset()
        imageMatrix = matrix
    }

    fun zoomBy(factor: Float) {
        val target = (currentScale * factor).coerceIn(MIN_SCALE, MAX_SCALE)
        val real = target / currentScale
        currentScale = target
        matrix.postScale(real, real, width / 2f, height / 2f)
        imageMatrix = matrix
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> lastTouch.set(event.x, event.y)
            MotionEvent.ACTION_MOVE -> {
                if (!scaleDetector.isInProgress) {
                    val dx = event.x - lastTouch.x
                    val dy = event.y - lastTouch.y
                    matrix.postTranslate(dx, dy)
                    imageMatrix = matrix
                    lastTouch.set(event.x, event.y)
                }
            }
            else -> {
                // 其它事件交给父类处理
            }
        }
        return true
    }

    companion object {
        private const val MIN_SCALE = 1f
        private const val MAX_SCALE = 5f
    }
}
