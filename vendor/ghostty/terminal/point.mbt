///|
pub(all) enum Tag {
  Active
  Viewport
  Screen
  History
} derive(Eq, Debug)

///|
struct Coordinate {
  x : CellCountInt
  y : UInt32
} derive(Eq, Debug)

///|
pub fn Coordinate::new(x : CellCountInt, y : UInt32) -> Coordinate {
  { x, y, }
}

///|
pub fn Coordinate::x(self : Coordinate) -> CellCountInt {
  self.x
}

///|
pub fn Coordinate::y(self : Coordinate) -> UInt32 {
  self.y
}

///|
pub(all) enum Point {
  Active(Coordinate)
  Viewport(Coordinate)
  Screen(Coordinate)
  History(Coordinate)
} derive(Eq, Debug)

///|
pub fn Point::coord(self : Point) -> Coordinate {
  match self {
    Active(coord) => coord
    Viewport(coord) => coord
    Screen(coord) => coord
    History(coord) => coord
  }
}
