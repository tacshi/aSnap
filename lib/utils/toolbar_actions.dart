import '../models/annotation.dart';

const _shapeToTool = <ShapeType, String>{
  ShapeType.rectangle: 'rectangle',
  ShapeType.ellipse: 'ellipse',
  ShapeType.arrow: 'arrow',
  ShapeType.line: 'line',
  ShapeType.pencil: 'pencil',
  ShapeType.marker: 'marker',
  ShapeType.mosaic: 'mosaic',
  ShapeType.number: 'number',
  ShapeType.text: 'text',
};

const _toolToShape = <String, ShapeType>{
  'rectangle': ShapeType.rectangle,
  'ellipse': ShapeType.ellipse,
  'arrow': ShapeType.arrow,
  'line': ShapeType.line,
  'pencil': ShapeType.pencil,
  'marker': ShapeType.marker,
  'mosaic': ShapeType.mosaic,
  'number': ShapeType.number,
  'text': ShapeType.text,
};

String? shapeTypeToToolId(ShapeType? type) =>
    type == null ? null : _shapeToTool[type];

ShapeType? toolIdToShapeType(String id) => _toolToShape[id];
