import '../models/annotation.dart';

String? shapeTypeToToolId(ShapeType? type) {
  switch (type) {
    case ShapeType.rectangle:
      return 'rectangle';
    case ShapeType.ellipse:
      return 'ellipse';
    case ShapeType.arrow:
      return 'arrow';
    case ShapeType.line:
      return 'line';
    case ShapeType.pencil:
      return 'pencil';
    case ShapeType.marker:
      return 'marker';
    case ShapeType.mosaic:
      return 'mosaic';
    case ShapeType.number:
      return 'number';
    case ShapeType.text:
      return 'text';
    case null:
      return null;
  }
}

ShapeType? toolIdToShapeType(String id) {
  switch (id) {
    case 'rectangle':
      return ShapeType.rectangle;
    case 'ellipse':
      return ShapeType.ellipse;
    case 'arrow':
      return ShapeType.arrow;
    case 'line':
      return ShapeType.line;
    case 'pencil':
      return ShapeType.pencil;
    case 'marker':
      return ShapeType.marker;
    case 'mosaic':
      return ShapeType.mosaic;
    case 'number':
      return ShapeType.number;
    case 'text':
      return ShapeType.text;
  }
  return null;
}
