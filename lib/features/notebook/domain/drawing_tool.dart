enum DrawingTool {
  pen,
  highlighter,
  eraserBrush,
  eraserStroke,
  line,
  arrow,
  rectangle,
  square,
  triangle,
  ellipse,
  circle,
  text,
  image,
  blockArrow,
  edit,
}

extension DrawingToolX on DrawingTool {
  bool get isEraser => this == DrawingTool.eraserBrush ||
      this == DrawingTool.eraserStroke;

  bool get isShape => this == DrawingTool.line ||
      this == DrawingTool.arrow ||
      this == DrawingTool.blockArrow ||
      this == DrawingTool.rectangle ||
      this == DrawingTool.square ||
      this == DrawingTool.triangle ||
      this == DrawingTool.ellipse ||
      this == DrawingTool.circle;

  bool get isInk => this == DrawingTool.pen ||
      this == DrawingTool.highlighter ||
      isEraser ||
      isShape;
}
