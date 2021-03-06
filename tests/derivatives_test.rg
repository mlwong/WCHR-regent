import "regent"

local c       = regentlib.c
local cmath   = terralib.includec("math.h")
local PI      = cmath.M_PI

require("fields")

-- Grid dimensions
local NX = 64
local NY = 64
local NZ = 64

-- Domain size
local LX = 2.0*math.pi
local LY = 2.0*math.pi
local LZ = 2.0*math.pi

local X1 = 0.0
local Y1 = 0.0
local Z1 = 0.0

-- Grid spacing
local DX = LX / NX
local DY = LY / NY
local DZ = LZ / NZ

local ONEBYDX = 1.0 / DX
local ONEBYDY = 1.0 / DY
local ONEBYDZ = 1.0 / DZ

-- Make the node and midpoint-node differencing tasks (Using pentadiagonal solver for this instead of tridiagonal solver)
require("derivatives")
local alpha10d1 = 1.0/3.0
local beta10d1  = 0.0
local a06d1 = ( 14.0/ 9.0)/2.0
local b06d1 = (  1.0/ 9.0)/4.0
local c06d1 = (  0.0/100.0)/6.0

-- Compact MND finite difference
local alpha06MND = -1.0/12.0
local beta06MND  = 0.0
local a06MND = 16.0/9.0
local b06MND = (-17.0/18.0)/2.0
local c06MND = (0.0)/3.0

-- Compact staggered finite difference
-- local alpha06MND = 9.0/62.0
-- local beta06MND  = 0.0
-- local a06MND = 63.0/62.0
-- local b06MND = (0.0/18.0)/2.0
-- local c06MND = (17.0/62.0)/3.0

local r_prim   = regentlib.newsymbol(region(ispace(int3d), primitive), "r_prim")
local r_prim_e = regentlib.newsymbol(region(ispace(int3d), primitive), "r_prim_e")
local r_der    = regentlib.newsymbol(region(ispace(int3d), primitive), "r_der")

local ddx     = make_ddx(r_prim, "rho", r_der, "rho", NX, NY, NZ, ONEBYDX, a06d1, b06d1, c06d1)
local ddy     = make_ddy(r_prim, "rho", r_der, "rho", NX, NY, NZ, ONEBYDX, a06d1, b06d1, c06d1)
local ddz     = make_ddz(r_prim, "rho", r_der, "rho", NX, NY, NZ, ONEBYDX, a06d1, b06d1, c06d1)

local ddx_MND = make_ddx_MND(r_prim, r_prim_e, "rho", r_der, "rho", NX, NY, NZ, ONEBYDX, a06MND, b06MND, c06MND)
local ddy_MND = make_ddy_MND(r_prim, r_prim_e, "rho", r_der, "rho", NX, NY, NZ, ONEBYDX, a06MND, b06MND, c06MND)
local ddz_MND = make_ddz_MND(r_prim, r_prim_e, "rho", r_der, "rho", NX, NY, NZ, ONEBYDX, a06MND, b06MND, c06MND)
-----------------------------------------------------

task initialize( coords     : region(ispace(int3d), coordinates),
                 r_prim_c   : region(ispace(int3d), primitive),
                 r_prim_l_x : region(ispace(int3d), primitive),
                 r_prim_l_y : region(ispace(int3d), primitive),
                 r_prim_l_z : region(ispace(int3d), primitive),
                 dx         : double,
                 dy         : double,
                 dz         : double )
where
  reads writes(coords, r_prim_c, r_prim_l_x, r_prim_l_y, r_prim_l_z)
do
  for i in coords.ispace do
    coords[i].x_c = X1 + (i.x + 0.5) * dx
    coords[i].y_c = Y1 + (i.y + 0.5) * dy
    coords[i].z_c = Z1 + (i.z + 0.5) * dz

    r_prim_c[i].rho = cmath.sin(coords[i].x_c) * cmath.cos(coords[i].y_c) * cmath.cos(coords[i].z_c)
  end

  for i in r_prim_l_x do
    var x_c : double = X1 + (i.x + 0.0) * dx
    var y_c : double = Y1 + (i.y + 0.5) * dy
    var z_c : double = Z1 + (i.z + 0.5) * dz

    r_prim_l_x[i].rho = cmath.sin(x_c) * cmath.cos(y_c) * cmath.cos(z_c)
  end

  for i in r_prim_l_y do
    var x_c : double = X1 + (i.x + 0.5) * dx
    var y_c : double = Y1 + (i.y + 0.0) * dy
    var z_c : double = Z1 + (i.z + 0.5) * dz

    r_prim_l_y[i].rho = cmath.sin(x_c) * cmath.cos(y_c) * cmath.cos(z_c)
  end

  for i in r_prim_l_z do
    var x_c : double = X1 + (i.x + 0.5) * dx
    var y_c : double = Y1 + (i.y + 0.5) * dy
    var z_c : double = Z1 + (i.z + 0.0) * dz

    r_prim_l_z[i].rho = cmath.sin(x_c) * cmath.cos(y_c) * cmath.cos(z_c)
  end

  return 1
end

task check_ddx( coords : region(ispace(int3d), coordinates),
                r_der  : region(ispace(int3d), primitive) )
where
  reads writes(coords, r_der)
do
  var err : double = 0.0
  for i in coords.ispace do
    var err_t : double = cmath.fabs( r_der[i].rho - cmath.cos(coords[i].x_c) * cmath.cos(coords[i].y_c) * cmath.cos(coords[i].z_c) )
    if err_t > err then
      err = err_t
    end
  end
  return err
end

task check_ddy( coords : region(ispace(int3d), coordinates),
                r_der  : region(ispace(int3d), primitive) )
where
  reads writes(coords, r_der)
do
  var err : double = 0.0
  for i in coords.ispace do
    var err_t : double = cmath.fabs( r_der[i].rho + cmath.sin(coords[i].x_c) * cmath.sin(coords[i].y_c) * cmath.cos(coords[i].z_c) )
    if err_t > err then
      err = err_t
    end
  end
  return err
end

task check_ddz( coords : region(ispace(int3d), coordinates),
                r_der  : region(ispace(int3d), primitive) )
where
  reads writes(coords, r_der)
do
  var err : double = 0.0
  for i in coords.ispace do
    var err_t : double = cmath.fabs( r_der[i].rho + cmath.sin(coords[i].x_c) * cmath.cos(coords[i].y_c) * cmath.sin(coords[i].z_c) )
    if err_t > err then
      err = err_t
    end
  end
  return err
end

terra wait_for(x : int)
  return x
end

task main()
  var Nx : int64 = NX
  var Ny : int64 = NY
  var Nz : int64 = NZ

  var Lx : double = LX
  var Ly : double = LY
  var Lz : double = LZ

  var dx : double = DX
  var dy : double = DY
  var dz : double = DZ

  c.printf("================ Problem parameters ================\n")
  c.printf("           Nx, Ny, Nz = %d, %d, %d\n", Nx, Ny, Nz)
  c.printf("           Lx, Ly, Lz = %f, %f, %f\n", Lx, Ly, Lz)
  c.printf("           dx, dy, dz = %f, %f, %f\n", dx, dy, dz)
  c.printf("====================================================\n")

  --------------------------------------------------------------------------------------------
  --                       DATA STUCTURES
  --------------------------------------------------------------------------------------------
  var grid_c     = ispace(int3d, {x = Nx,   y = Ny,   z = Nz  })  -- Cell center index space

  var grid_e_x   = ispace(int3d, {x = Nx+1, y = Ny,   z = Nz  })  -- x cell edge index space
  var grid_e_y   = ispace(int3d, {x = Nx,   y = Ny+1, z = Nz  })  -- y cell edge index space
  var grid_e_z   = ispace(int3d, {x = Nx,   y = Ny,   z = Nz+1})  -- z cell edge index space

  var coords     = region(grid_c, coordinates)  -- Coordinates of cell center

  var r_prim_c   = region(grid_c,   primitive)  -- Primitive variables at cell center
  var r_prim_l_x = region(grid_e_x, primitive)  -- Primitive variables at left x cell edge
  var r_prim_l_y = region(grid_e_y, primitive)  -- Primitive variables at left y cell edge
  var r_prim_l_z = region(grid_e_z, primitive)  -- Primitive variables at left z cell edge
  
  var r_der      = region(grid_c,   primitive)  -- RHS for time stepping at cell center

  var LU_x       = region(ispace(int3d, {x = Nx, y = 1, z = 1}), LU_struct) -- Data structure to hold x derivative LU decomposition
  var LU_y       = region(ispace(int3d, {x = Ny, y = 1, z = 1}), LU_struct) -- Data structure to hold y derivative LU decomposition
  var LU_z       = region(ispace(int3d, {x = Nz, y = 1, z = 1}), LU_struct) -- Data structure to hold z derivative LU decomposition

  var pgrid_x    = ispace(int2d, {x = 1, y = 1}) -- Processor grid in x
  var pgrid_y    = ispace(int2d, {x = 1, y = 1}) -- Processor grid in y
  var pgrid_z    = ispace(int2d, {x = 1, y = 1}) -- Processor grid in z
  --------------------------------------------------------------------------------------------
  --------------------------------------------------------------------------------------------

  var token = initialize(coords, r_prim_c, r_prim_l_x, r_prim_l_y, r_prim_l_z, dx, dy, dz)
  wait_for(token)

  var err = 0.0

  fill(r_der.rho, 0.0)
  get_LU_decomposition(LU_x, beta10d1, alpha10d1, 1.0, alpha10d1, beta10d1)
  token += ddx(r_prim_c, r_der, LU_x)
  wait_for(token)
  err = check_ddx(coords, r_der)
  c.printf("Error in ddx     = %g\n", err)
  regentlib.assert( err <= 1.e-9, "Derivative test failed for task ddx")

  fill(r_der.rho, 0.0)
  get_LU_decomposition(LU_y, beta10d1, alpha10d1, 1.0, alpha10d1, beta10d1)
  token += ddy(r_prim_c, r_der, LU_y)
  wait_for(token)
  err = check_ddy(coords, r_der)
  c.printf("Error in ddy     = %g\n", err)
  regentlib.assert( err <= 1.e-9, "Derivative test failed for task ddy")

  fill(r_der.rho, 0.0)
  get_LU_decomposition(LU_z, beta10d1, alpha10d1, 1.0, alpha10d1, beta10d1)
  token += ddz(r_prim_c, r_der, LU_z)
  wait_for(token)
  err = check_ddz(coords, r_der)
  c.printf("Error in ddz     = %g\n", err)
  regentlib.assert( err <= 1.e-9, "Derivative test failed for task ddz")

  c.printf("\n")

  fill(r_der.rho, 0.0)
  get_LU_decomposition(LU_x, beta06MND, alpha06MND, 1.0, alpha06MND, beta06MND)
  token += ddx_MND(r_prim_c, r_prim_l_x, r_der, LU_x)
  wait_for(token)
  err = check_ddx(coords, r_der)
  c.printf("Error in ddx_MND = %g\n", err)
  regentlib.assert( err <= 1.e-09, "Derivative test failed for task ddx_MND")

  fill(r_der.rho, 0.0)
  get_LU_decomposition(LU_y, beta06MND, alpha06MND, 1.0, alpha06MND, beta06MND)
  token += ddy_MND(r_prim_c, r_prim_l_y, r_der, LU_y)
  wait_for(token)
  err = check_ddy(coords, r_der)
  c.printf("Error in ddy_MND = %g\n", err)
  regentlib.assert( err <= 1.e-09, "Derivative test failed for task ddy_MND")

  fill(r_der.rho, 0.0)
  get_LU_decomposition(LU_z, beta06MND, alpha06MND, 1.0, alpha06MND, beta06MND)
  token += ddz_MND(r_prim_c, r_prim_l_z, r_der, LU_z)
  wait_for(token)
  err = check_ddz(coords, r_der)
  c.printf("Error in ddz_MND = %g\n", err)
  regentlib.assert( err <= 1.e-09, "Derivative test failed for task ddz_MND")

  c.printf("\nAll tests passed! :)\n")
end

regentlib.start(main)
