class_name LowPolyMesh
extends RefCounted


static func beveled_box(size: Vector3, requested_bevel: float) -> ArrayMesh:
	var half_size := size * 0.5
	var bevel := clampf(
		requested_bevel,
		0.001,
		minf(half_size.x, minf(half_size.y, half_size.z)) * 0.46
	)
	var inner := half_size - Vector3.ONE * bevel
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Six broad faces retain the deliberately planar low-poly look.
	for sign_x in [-1.0, 1.0]:
		_add_quad(surface, [
			Vector3(sign_x * half_size.x, -inner.y, -inner.z),
			Vector3(sign_x * half_size.x, -inner.y, inner.z),
			Vector3(sign_x * half_size.x, inner.y, inner.z),
			Vector3(sign_x * half_size.x, inner.y, -inner.z),
		], Vector3(sign_x, 0.0, 0.0))
	for sign_y in [-1.0, 1.0]:
		_add_quad(surface, [
			Vector3(-inner.x, sign_y * half_size.y, -inner.z),
			Vector3(inner.x, sign_y * half_size.y, -inner.z),
			Vector3(inner.x, sign_y * half_size.y, inner.z),
			Vector3(-inner.x, sign_y * half_size.y, inner.z),
		], Vector3(0.0, sign_y, 0.0))
	for sign_z in [-1.0, 1.0]:
		_add_quad(surface, [
			Vector3(-inner.x, -inner.y, sign_z * half_size.z),
			Vector3(inner.x, -inner.y, sign_z * half_size.z),
			Vector3(inner.x, inner.y, sign_z * half_size.z),
			Vector3(-inner.x, inner.y, sign_z * half_size.z),
		], Vector3(0.0, 0.0, sign_z))

	# Twelve chamfer faces catch thin highlights along every long edge.
	for sign_y in [-1.0, 1.0]:
		for sign_z in [-1.0, 1.0]:
			_add_quad(surface, [
				Vector3(-inner.x, sign_y * half_size.y, sign_z * inner.z),
				Vector3(inner.x, sign_y * half_size.y, sign_z * inner.z),
				Vector3(inner.x, sign_y * inner.y, sign_z * half_size.z),
				Vector3(-inner.x, sign_y * inner.y, sign_z * half_size.z),
			], Vector3(0.0, sign_y, sign_z).normalized())
	for sign_x in [-1.0, 1.0]:
		for sign_z in [-1.0, 1.0]:
			_add_quad(surface, [
				Vector3(sign_x * half_size.x, -inner.y, sign_z * inner.z),
				Vector3(sign_x * half_size.x, inner.y, sign_z * inner.z),
				Vector3(sign_x * inner.x, inner.y, sign_z * half_size.z),
				Vector3(sign_x * inner.x, -inner.y, sign_z * half_size.z),
			], Vector3(sign_x, 0.0, sign_z).normalized())
	for sign_x in [-1.0, 1.0]:
		for sign_y in [-1.0, 1.0]:
			_add_quad(surface, [
				Vector3(sign_x * half_size.x, sign_y * inner.y, -inner.z),
				Vector3(sign_x * half_size.x, sign_y * inner.y, inner.z),
				Vector3(sign_x * inner.x, sign_y * half_size.y, inner.z),
				Vector3(sign_x * inner.x, sign_y * half_size.y, -inner.z),
			], Vector3(sign_x, sign_y, 0.0).normalized())

	# Eight triangular corner facets finish the silhouette without smoothing it.
	for sign_x in [-1.0, 1.0]:
		for sign_y in [-1.0, 1.0]:
			for sign_z in [-1.0, 1.0]:
				_add_triangle(surface,
					Vector3(sign_x * half_size.x, sign_y * inner.y, sign_z * inner.z),
					Vector3(sign_x * inner.x, sign_y * half_size.y, sign_z * inner.z),
					Vector3(sign_x * inner.x, sign_y * inner.y, sign_z * half_size.z),
					Vector3(sign_x, sign_y, sign_z).normalized()
				)

	return surface.commit()


static func soft_disc(segments := 32) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in segments:
		var angle_a := TAU * float(index) / float(segments)
		var angle_b := TAU * float(index + 1) / float(segments)
		var edge_a := Vector3(cos(angle_a), 0.0, sin(angle_a))
		var edge_b := Vector3(cos(angle_b), 0.0, sin(angle_b))
		surface.set_normal(Vector3.UP)
		surface.set_color(Color(1.0, 1.0, 1.0, 0.19))
		surface.add_vertex(Vector3.ZERO)
		surface.set_normal(Vector3.UP)
		surface.set_color(Color(1.0, 1.0, 1.0, 0.0))
		surface.add_vertex(edge_b)
		surface.set_normal(Vector3.UP)
		surface.set_color(Color(1.0, 1.0, 1.0, 0.0))
		surface.add_vertex(edge_a)
	return surface.commit()


static func ribbon(points: Array[Vector3], width: float, normal_offset := 0.0) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	if points.size() < 2:
		return surface.commit()
	var frames := _ribbon_frames(points, width, normal_offset)
	var left: Array[Vector3] = frames["left"]
	var right: Array[Vector3] = frames["right"]
	var normals: Array[Vector3] = frames["normals"]
	for index in points.size() - 1:
		_add_smooth_triangle(
			surface,
			left[index],
			left[index + 1],
			right[index + 1],
			normals[index],
			normals[index + 1],
			normals[index + 1]
		)
		_add_smooth_triangle(
			surface,
			left[index],
			right[index + 1],
			right[index],
			normals[index],
			normals[index + 1],
			normals[index]
		)
	return surface.commit()


static func ribbon_collision_faces(
	points: Array[Vector3],
	width: float,
	normal_offset := 0.0
) -> PackedVector3Array:
	var faces := PackedVector3Array()
	if points.size() < 2:
		return faces
	var frames := _ribbon_frames(points, width, normal_offset)
	var left: Array[Vector3] = frames["left"]
	var right: Array[Vector3] = frames["right"]
	for index in points.size() - 1:
		# Godot uses clockwise front faces. These wind upward when viewed from
		# the driveable side of the ribbon.
		faces.append(left[index])
		faces.append(right[index + 1])
		faces.append(left[index + 1])
		faces.append(left[index])
		faces.append(right[index])
		faces.append(right[index + 1])
	return faces


static func _ribbon_frames(
	points: Array[Vector3],
	width: float,
	normal_offset: float
) -> Dictionary:
	var left: Array[Vector3] = []
	var right: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var half_width := width * 0.5
	for index in points.size():
		var previous := points[maxi(0, index - 1)]
		var following := points[mini(points.size() - 1, index + 1)]
		var tangent := (following - previous).normalized()
		var lateral := Vector3.UP.cross(tangent).normalized()
		if lateral.length_squared() < 0.001:
			lateral = Vector3.RIGHT
		var normal := tangent.cross(lateral).normalized()
		var center := points[index] + normal * normal_offset
		left.append(center - lateral * half_width)
		right.append(center + lateral * half_width)
		normals.append(normal)
	return {
		"left": left,
		"right": right,
		"normals": normals,
	}


static func _add_quad(surface: SurfaceTool, vertices: Array[Vector3], normal: Vector3) -> void:
	_add_triangle(surface, vertices[0], vertices[1], vertices[2], normal)
	_add_triangle(surface, vertices[0], vertices[2], vertices[3], normal)


static func _add_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	# Godot treats clockwise triangles as front-facing. Swap the last vertices
	# whenever the mathematical cross product points along the outward normal.
	if (b - a).cross(c - a).dot(normal) > 0.0:
		var swap := b
		b = c
		c = swap
	for vertex in [a, b, c]:
		surface.set_normal(normal)
		surface.add_vertex(vertex)


static func _add_smooth_triangle(
	surface: SurfaceTool,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	normal_a: Vector3,
	normal_b: Vector3,
	normal_c: Vector3
) -> void:
	var expected_normal := (normal_a + normal_b + normal_c).normalized()
	if (b - a).cross(c - a).dot(expected_normal) > 0.0:
		var swap_vertex := b
		b = c
		c = swap_vertex
		var swap_normal := normal_b
		normal_b = normal_c
		normal_c = swap_normal
	for vertex_data in [
		[a, normal_a],
		[b, normal_b],
		[c, normal_c],
	]:
		surface.set_normal(vertex_data[1])
		surface.add_vertex(vertex_data[0])
