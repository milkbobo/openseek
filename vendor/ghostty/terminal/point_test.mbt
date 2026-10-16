///|
test "point/coord returns payload" {
  let coord : @terminal.Coordinate = @terminal.Coordinate::new(42, 80)
  let point = @terminal.Point::Viewport(coord)
  guard point.coord() == coord else { fail("expected coord payload") }
}

///|
test "point/coordinate equality checks both axes" {
  let a : @terminal.Coordinate = @terminal.Coordinate::new(12, 34)
  let b : @terminal.Coordinate = @terminal.Coordinate::new(12, 34)
  let c : @terminal.Coordinate = @terminal.Coordinate::new(12, 35)
  guard a == b else { fail("expected equal coordinates") }
  guard a != c else { fail("expected differing y coordinate") }
}

///|
test "point/constructors cover all point tags" {
  let coord : @terminal.Coordinate = @terminal.Coordinate::new(1, 2)
  ignore(@terminal.Tag::Active)
  ignore(@terminal.Tag::Viewport)
  ignore(@terminal.Tag::Screen)
  ignore(@terminal.Tag::History)
  ignore(@terminal.Point::Active(coord))
  ignore(@terminal.Point::Viewport(coord))
  ignore(@terminal.Point::Screen(coord))
  ignore(@terminal.Point::History(coord))
}

///|
test "point/coord handles every point variant" {
  let coords : Array[@terminal.Coordinate] = [
    @terminal.Coordinate::new(3, 4),
    @terminal.Coordinate::new(5, 6),
    @terminal.Coordinate::new(7, 8),
    @terminal.Coordinate::new(9, 10),
  ]
  let points : Array[@terminal.Point] = [
    Active(coords[0]),
    Viewport(coords[1]),
    Screen(coords[2]),
    History(coords[3]),
  ]

  for i in 0..<points.length() {
    guard points[i].coord() == coords[i] else {
      fail("expected point variant to preserve coordinate payload")
    }
  }
}

///|
test "point/coordinate constructor and accessors" {
  let coord = @terminal.Coordinate::new(7, 9)
  assert_eq(coord.x(), 7)
  assert_eq(coord.y(), 9)
}
