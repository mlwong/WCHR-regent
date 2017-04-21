import "regent"

local c       = regentlib.c
local cmath   = terralib.includec("math.h")
local PI      = cmath.M_PI
local cstring = terralib.includec("string.h")
local min     = regentlib.fmin

require("fields")
require("derivatives")
require("IO")
require("SOE")
require("RHS")
require("partition")

local superlu = require("superlu_util")
local problem = require("problem")
local Config  = require("config")

local csuperlu_mapper = require("superlu_mapper")

terra wait_for(x : int)
  return x
end

task main()
  var Nx : int64 = problem.NX
  var Ny : int64 = problem.NY
  var Nz : int64 = problem.NZ

  var Lx : double = problem.LX
  var Ly : double = problem.LY
  var Lz : double = problem.LZ

  var dx : double = problem.DX
  var dy : double = problem.DY
  var dz : double = problem.DZ
  
  -- Get time settings.
  var timestepping_setting = problem.timestepping_setting
  
  var dt      : double = 0.0
  var CFL_num : double = 0.0

  if cstring.strcmp(timestepping_setting, "CONSTANT_TIME_STEPPING") == 0 then
    dt = problem.dt_or_CFL_num
  elseif cstring.strcmp(timestepping_setting, "CONSTANT_CFL_NUM") == 0 then
    CFL_num = problem.dt_or_CFL_num
  else
    regentlib.assert( false, "Unknown time stepping setting! Choose between \"CONSTANT_TIME_STEPPING\" or \"CONSTANT_CFL_NUM\"!" )
  end


  var tstop    : double = problem.tstop
  var tsim     : double = 0.0
  var step     : int64  = 0
  var tviz     : double = problem.tviz
  var vizcount : int    = 0
  var vizcond  : bool   = true

  var config : Config
  config:initialize_from_command(Nx, Ny, Nz)

  c.printf("======================= Problem parameters ======================\n")
  c.printf("           Nx, Ny, Nz           = %d, %d, %d\n", Nx, Ny, Nz)
  c.printf("           Lx, Ly, Lz           = %f, %f, %f\n", Lx, Ly, Lz)
  c.printf("           dx, dy, dz           = %f, %f, %f\n", dx, dy, dz)
  c.printf("           Time stepping method = ")
  c.printf(timestepping_setting)
  c.printf("\n")
  if cstring.strcmp(timestepping_setting, "CONSTANT_TIME_STEPPING") == 0 then
    c.printf("           dt                   = %f\n", dt)
  elseif cstring.strcmp(timestepping_setting, "CONSTANT_CFL_NUM") == 0 then
    c.printf("           CFL_num              = %f\n", CFL_num)
  end
  
  c.printf("           prow, pcol           = %d, %d\n", config.prow, config.pcol)
  if config.fileIO then
    c.printf("           fileIO               = true\n")
    c.printf("           prefix               = %s\n", config.filename_prefix)
  else
    c.printf("           fileIO               = false\n")
  end

  c.printf("================================================================\n")

  --------------------------------------------------------------------------------------------
  --                       DATA STUCTURES
  --------------------------------------------------------------------------------------------
  
  var grid_c     = ispace(int3d, {x = Nx,   y = Ny,   z = Nz  })  -- cell center index space

  var grid_e_x   = ispace(int3d, {x = Nx+1, y = Ny,   z = Nz  })  -- x cell edge index space
  var grid_e_y   = ispace(int3d, {x = Nx,   y = Ny+1, z = Nz  })  -- y cell edge index space
  var grid_e_z   = ispace(int3d, {x = Nx,   y = Ny,   z = Nz+1})  -- z cell edge index space

  var coords     = region(grid_c, coordinates)  -- coordinates of cell center

  var r_cnsr     = region(grid_c,   conserved)  -- conserved variables at cell center

  var r_prim_c   = region(grid_c,   primitive)  -- primitive variables at cell center
  var r_prim_l_x = region(grid_e_x, primitive)  -- primitive variables at left x cell edge
  var r_prim_l_y = region(grid_e_y, primitive)  -- primitive variables at left y cell edge
  var r_prim_l_z = region(grid_e_z, primitive)  -- primitive variables at left z cell edge
  var r_prim_r_x = region(grid_e_x, primitive)  -- primitive variables at right x cell edge
  var r_prim_r_y = region(grid_e_y, primitive)  -- primitive variables at right y cell edge
  var r_prim_r_z = region(grid_e_z, primitive)  -- primitive variables at right z cell edge

  var r_rhs_l_x  = region(grid_e_x, primitive)  -- store RHS for left interpolation in x
  var r_rhs_r_x  = region(grid_e_x, primitive)  -- store RHS for right interpolation in x
  var r_rhs_l_y  = region(grid_e_y, primitive)  -- store RHS for left interpolation in y
  var r_rhs_r_y  = region(grid_e_y, primitive)  -- store RHS for right interpolation in y
  var r_rhs_l_z  = region(grid_e_z, primitive)  -- store RHS for left interpolation in z
  var r_rhs_r_z  = region(grid_e_z, primitive)  -- store RHS for right interpolation in z

  var r_flux_c   = region(grid_c,   conserved)  -- flux at cell center
  var r_flux_e_x = region(grid_e_x, conserved)  -- flux at x cell edge
  var r_flux_e_y = region(grid_e_y, conserved)  -- flux at y cell edge
  var r_flux_e_z = region(grid_e_z, conserved)  -- flux at z cell edge
  
  var r_fder_c_x = region(grid_c,   conserved)  -- x flux derivative
  var r_fder_c_y = region(grid_c,   conserved)  -- y flux derivative
  var r_fder_c_z = region(grid_c,   conserved)  -- z flux derivative
  
  var r_cnsr_1   = region(grid_c,   conserved)  -- conserved variables at cell center for TVD-RK3
  var r_cnsr_2   = region(grid_c,   conserved)  -- conserved variables at cell center for TVD-RK3
  
  var r_rhs_0    = region(grid_c,   conserved)  -- RHS for time stepping at cell center for TVD-RK3
  var r_rhs_1    = region(grid_c,   conserved)  -- RHS for time stepping at cell center for TVD-RK3
  var r_rhs_2    = region(grid_c,   conserved)  -- RHS for time stepping at cell center for TVD-RK3

  -- data structure to hold x derivative LU decomposition
  var LU_x       = region(ispace(int3d, {x = Nx, y = config.prow, z = config.pcol}), LU_struct)
  
  -- data structure to hold y derivative LU decomposition
  var LU_y       = region(ispace(int3d, {x = Ny, y = config.prow, z = config.pcol}), LU_struct)

  -- data structure to hold z derivative LU decomposition
  var LU_z       = region(ispace(int3d, {x = Nz, y = config.prow, z = config.pcol}), LU_struct)

  var pencil = ispace(int2d, int2d {config.prow, config.pcol})

  var slu_l_x    = region(pencil, superlu.c.superlu_vars_t)  -- Super LU data structure for x interpolation
  var slu_r_x    = region(pencil, superlu.c.superlu_vars_t)  -- Super LU data structure for x interpolation
  var slu_l_y    = region(pencil, superlu.c.superlu_vars_t)  -- Super LU data structure for y interpolation
  var slu_r_y    = region(pencil, superlu.c.superlu_vars_t)  -- Super LU data structure for y interpolation
  var slu_l_z    = region(pencil, superlu.c.superlu_vars_t)  -- Super LU data structure for z interpolation
  var slu_r_z    = region(pencil, superlu.c.superlu_vars_t)  -- Super LU data structure for z interpolation

  var matrix_l_x = region(pencil, superlu.CSR_matrix)  -- matrix data structure for x left interpolation
  var matrix_r_x = region(pencil, superlu.CSR_matrix)  -- matrix data structure for x right interpolation
  var matrix_l_y = region(pencil, superlu.CSR_matrix)  -- matrix data structure for y left interpolation
  var matrix_r_y = region(pencil, superlu.CSR_matrix)  -- matrix data structure for y right interpolation
  var matrix_l_z = region(pencil, superlu.CSR_matrix)  -- matrix data structure for z left interpolation
  var matrix_r_z = region(pencil, superlu.CSR_matrix)  -- matrix data structure for z right interpolation
  
  --------------------------------------------------------------------------------------------
  --------------------------------------------------------------------------------------------

  --------------------------------------------------------------------------------------------
  --                       PARTITIONING
  --------------------------------------------------------------------------------------------
  
  var p_coords_x   = partition_xpencil_coords(coords,   pencil)
  var p_coords_y   = partition_ypencil_coords(coords,   pencil)
  var p_coords_z   = partition_zpencil_coords(coords,   pencil)

  var p_cnsr_x     = partition_xpencil_cnsr(r_cnsr,     pencil)
  var p_cnsr_y     = partition_ypencil_cnsr(r_cnsr,     pencil)
  var p_cnsr_z     = partition_zpencil_cnsr(r_cnsr,     pencil)

  var p_prim_c_x   = partition_xpencil_prim(r_prim_c,   pencil)
  var p_prim_c_y   = partition_ypencil_prim(r_prim_c,   pencil)
  var p_prim_c_z   = partition_zpencil_prim(r_prim_c,   pencil)

  var p_prim_l_x   = partition_xpencil_prim(r_prim_l_x, pencil)
  var p_prim_l_y   = partition_ypencil_prim(r_prim_l_y, pencil)
  var p_prim_l_z   = partition_zpencil_prim(r_prim_l_z, pencil)

  var p_prim_r_x   = partition_xpencil_prim(r_prim_r_x, pencil)
  var p_prim_r_y   = partition_ypencil_prim(r_prim_r_y, pencil)
  var p_prim_r_z   = partition_zpencil_prim(r_prim_r_z, pencil)

  var p_rhs_l_x    = partition_xpencil_prim(r_rhs_l_x,  pencil)
  var p_rhs_l_y    = partition_ypencil_prim(r_rhs_l_y,  pencil)
  var p_rhs_l_z    = partition_zpencil_prim(r_rhs_l_z,  pencil)

  var p_rhs_r_x    = partition_xpencil_prim(r_rhs_r_x,  pencil)
  var p_rhs_r_y    = partition_ypencil_prim(r_rhs_r_y,  pencil)
  var p_rhs_r_z    = partition_zpencil_prim(r_rhs_r_z,  pencil)

  var p_flux_c_x   = partition_xpencil_cnsr(r_flux_c,   pencil)
  var p_flux_c_y   = partition_ypencil_cnsr(r_flux_c,   pencil)
  var p_flux_c_z   = partition_zpencil_cnsr(r_flux_c,   pencil)

  var p_flux_e_x   = partition_xpencil_cnsr(r_flux_e_x, pencil)
  var p_flux_e_y   = partition_ypencil_cnsr(r_flux_e_y, pencil)
  var p_flux_e_z   = partition_zpencil_cnsr(r_flux_e_z, pencil)

  var p_fder_c_x   = partition_xpencil_cnsr(r_fder_c_x, pencil)
  var p_fder_c_y   = partition_ypencil_cnsr(r_fder_c_y, pencil)
  var p_fder_c_z   = partition_zpencil_cnsr(r_fder_c_z, pencil)
  
  var p_cnsr_x_1   = partition_xpencil_cnsr(r_cnsr_1,   pencil)
  var p_cnsr_y_1   = partition_ypencil_cnsr(r_cnsr_1,   pencil)
  var p_cnsr_z_1   = partition_zpencil_cnsr(r_cnsr_1,   pencil)

  var p_cnsr_x_2   = partition_xpencil_cnsr(r_cnsr_2,   pencil)
  var p_cnsr_y_2   = partition_ypencil_cnsr(r_cnsr_2,   pencil)
  var p_cnsr_z_2   = partition_zpencil_cnsr(r_cnsr_2,   pencil)

  var p_rhs_x_0    = partition_xpencil_cnsr(r_rhs_0,    pencil)
  var p_rhs_y_0    = partition_ypencil_cnsr(r_rhs_0,    pencil)
  var p_rhs_z_0    = partition_zpencil_cnsr(r_rhs_0,    pencil)

  var p_rhs_x_1    = partition_xpencil_cnsr(r_rhs_1,    pencil)
  var p_rhs_y_1    = partition_ypencil_cnsr(r_rhs_1,    pencil)
  var p_rhs_z_1    = partition_zpencil_cnsr(r_rhs_1,    pencil)

  var p_rhs_x_2    = partition_xpencil_cnsr(r_rhs_2,    pencil)
  var p_rhs_y_2    = partition_ypencil_cnsr(r_rhs_2,    pencil)
  var p_rhs_z_2    = partition_zpencil_cnsr(r_rhs_2,    pencil)

  var p_LU_x       = partition_LU(LU_x,                 pencil)
  var p_LU_y       = partition_LU(LU_y,                 pencil)
  var p_LU_z       = partition_LU(LU_z,                 pencil)

  var p_slu_l_x    = partition_slu(slu_l_x,             pencil)
  var p_slu_r_x    = partition_slu(slu_r_x,             pencil)
  var p_slu_l_y    = partition_slu(slu_l_y,             pencil)
  var p_slu_r_y    = partition_slu(slu_r_y,             pencil)
  var p_slu_l_z    = partition_slu(slu_l_z,             pencil)
  var p_slu_r_z    = partition_slu(slu_r_z,             pencil)

  var p_matrix_l_x = partition_matrix(matrix_l_x,       pencil)
  var p_matrix_l_y = partition_matrix(matrix_l_y,       pencil)
  var p_matrix_l_z = partition_matrix(matrix_l_z,       pencil)

  var p_matrix_r_x = partition_matrix(matrix_r_x,       pencil)
  var p_matrix_r_y = partition_matrix(matrix_r_y,       pencil)
  var p_matrix_r_z = partition_matrix(matrix_r_z,       pencil)

  --------------------------------------------------------------------------------------------
  --------------------------------------------------------------------------------------------

  var token : int = 0

  -- Initialize characteristic interpolation matrices and SuperLU structs.
  if Nx >= 8 then
    __demand(__parallel)
    for i in pencil do
      token += superlu.initialize_matrix_char_x(p_matrix_l_x[i], alpha06CI, beta06CI, gamma06CI, Nx, Ny/config.prow, Nz/config.pcol)
    end

    __demand(__parallel)
    for i in pencil do
      token += superlu.initialize_matrix_char_x(p_matrix_r_x[i], alpha06CI, beta06CI, gamma06CI, Nx, Ny/config.prow, Nz/config.pcol)
    end

    __demand(__parallel)
    for i in pencil do
      token += set_zero_prim( p_rhs_l_x[i] )
    end

    __demand(__parallel)
    for i in pencil do
      token += superlu.init_superlu_vars( p_matrix_l_x[i], 5*(Nx+1)*Ny/config.prow*Nz/config.pcol, p_rhs_l_x[i], p_prim_l_x[i], p_slu_l_x[i] )
    end

    __demand(__parallel)
    for i in pencil do
      token += set_zero_prim( p_rhs_r_x[i] )
    end

    __demand(__parallel)
    for i in pencil do
      token += superlu.init_superlu_vars( p_matrix_r_x[i], 5*(Nx+1)*Ny/config.prow*Nz/config.pcol, p_rhs_r_x[i], p_prim_r_x[i], p_slu_r_x[i] )
    end
  end
  wait_for(token)
  c.printf("Finished X matrices initialization\n")

  if Ny >= 8 then
    __demand(__parallel)
    for i in pencil do
      token += superlu.initialize_matrix_char_y(p_matrix_l_y[i], alpha06CI, beta06CI, gamma06CI, Nx/config.prow, Ny, Nz/config.pcol)
    end

    __demand(__parallel)
    for i in pencil do
      token += superlu.initialize_matrix_char_y(p_matrix_r_y[i], alpha06CI, beta06CI, gamma06CI, Nx/config.prow, Ny, Nz/config.pcol)
    end

    __demand(__parallel)
    for i in pencil do
      token += set_zero_prim( p_rhs_l_y[i] )
    end

    __demand(__parallel)
    for i in pencil do
      token += superlu.init_superlu_vars( p_matrix_l_y[i], 5*Nx/config.prow*(Ny+1)*Nz/config.pcol, p_rhs_l_y[i], p_prim_l_y[i], p_slu_l_y[i] )
    end

    __demand(__parallel)
    for i in pencil do
      token += set_zero_prim( p_rhs_r_y[i] )
    end

    __demand(__parallel)
    for i in pencil do
      token += superlu.init_superlu_vars( p_matrix_r_y[i], 5*Nx/config.prow*(Ny+1)*Nz/config.pcol, p_rhs_r_y[i], p_prim_r_y[i], p_slu_r_y[i] )
    end
  end
  wait_for(token)
  c.printf("Finished Y matrices initialization\n")

  if Nz >= 8 then
    __demand(__parallel)
    for i in pencil do
      token += superlu.initialize_matrix_char_z(p_matrix_l_z[i], alpha06CI, beta06CI, gamma06CI, Nx/config.prow, Ny/config.pcol, Nz)
    end

    __demand(__parallel)
    for i in pencil do
      token += superlu.initialize_matrix_char_z(p_matrix_r_z[i], alpha06CI, beta06CI, gamma06CI, Nx/config.prow, Ny/config.pcol, Nz)
    end

    __demand(__parallel)
    for i in pencil do
      token += set_zero_prim( p_rhs_l_z[i] )
    end

    __demand(__parallel)
    for i in pencil do
      token += superlu.init_superlu_vars( p_matrix_l_z[i], 5*Nx/config.prow*Ny/config.pcol*(Nz+1), p_rhs_l_z[i], p_prim_l_z[i], p_slu_l_z[i] )
    end

    __demand(__parallel)
    for i in pencil do
      token += set_zero_prim( p_rhs_r_z[i] )
    end

    __demand(__parallel)
    for i in pencil do
      token += superlu.init_superlu_vars( p_matrix_r_z[i], 5*Nx/config.prow*Ny/config.pcol*(Nz+1), p_rhs_r_z[i], p_prim_r_z[i], p_slu_r_z[i] )
    end
  end
  wait_for(token)
  c.printf("Finished Z matrices initialization\n")
  
  -- Initialize derivatives stuff.
  __demand(__parallel)
  for i in pencil do
    token += get_LU_decomposition(p_LU_x[i], beta06MND, alpha06MND, 1.0, alpha06MND, beta06MND)
  end
  __demand(__parallel)
  for i in pencil do
    token += get_LU_decomposition(p_LU_y[i], beta06MND, alpha06MND, 1.0, alpha06MND, beta06MND)
  end
  __demand(__parallel)
  for i in pencil do
    token += get_LU_decomposition(p_LU_z[i], beta06MND, alpha06MND, 1.0, alpha06MND, beta06MND)
  end
  wait_for(token)
  c.printf("Finished LU initialization\n")

  __demand(__parallel)
  for i in pencil do
    -- Initialize everything in y decomposition.
    token += problem.initialize(p_coords_y[i], p_prim_c_y[i], dx, dy, dz)
  end
  wait_for(token)
  c.printf("Finished initialization\n")
  
  var TKE0 : double = 0.0
  __demand(__parallel)
  for i in pencil do
    TKE0 += problem.TKE(p_prim_c_y[i])
  end

  -- var IOtoken = 0
  -- if config.fileIO then
  --   IOtoken += write_coords(coords, config.filename_prefix)
  -- end
  
  -- Get conserved variables after initialization.
  __demand(__parallel)
  for i in pencil do
    token += get_conserved_r(p_prim_c_y[i], p_cnsr_y[i])
  end

  -- if config.fileIO then
  --   if vizcond then
  --     wait_for(IOtoken)
  --     IOtoken += write_primitive(r_prim_c, config.filename_prefix, vizcount)
  --     vizcount = vizcount + 1
  --     vizcond = false
  --     dt = problem.dt
  --   end
  --   if tsim + dt >= tviz*vizcount then
  --     dt = tviz * vizcount - tsim
  --     vizcond = true
  --   end
  -- end
  
  wait_for(token)
  var t_start = c.legion_get_current_time_in_micros()

  __demand(__spmd)
  while tsim < tstop*(1.0 - 1.0e-16) do
    if cstring.strcmp(timestepping_setting, "CONSTANT_CFL_NUM") == 0 then
      -- Get stable dt.
      dt = dt/0.0
      if Nz >= 8 then
        __demand(__parallel)
        for i in pencil do
          dt min= get_max_stable_dt_3d(p_prim_c_y[i], dx, dy, dz)
        end
      elseif Ny >= 8 then
        __demand(__parallel)
        for i in pencil do
          dt min= get_max_stable_dt_2d(p_prim_c_y[i], dx, dy)
        end
      else
        __demand(__parallel)
        for i in pencil do
          dt min= get_max_stable_dt_1d(p_prim_c_y[i], dx)
        end
      end
    end

    dt *= CFL_num

    --------------------------------------------------------------------------------------------
    -- Advance first sub-step.
    --------------------------------------------------------------------------------------------

    -- Set RHS to zero.
    __demand(__parallel)
    for i in pencil do
      set_zero_cnsr( p_rhs_y_0[i] )
    end 

    -- Add x-direction flux derivative to RHS.
    __demand(__parallel)
    for i in pencil do
      add_xflux_der_to_rhs( p_cnsr_x[i], p_prim_c_x[i], p_prim_l_x[i], p_prim_r_x[i], p_rhs_l_x[i], p_rhs_r_x[i],
                            p_flux_c_x[i], p_flux_e_x[i], p_fder_c_x[i], p_rhs_x_0[i],
                            p_LU_x[i], p_slu_l_x[i], p_slu_r_x[i], p_matrix_l_x[i], p_matrix_r_x[i],
                            Nx, Ny, Nz )
    end

    -- Add y-direction flux derivative to RHS.
    __demand(__parallel)
    for i in pencil do
      add_yflux_der_to_rhs( p_cnsr_y[i], p_prim_c_y[i], p_prim_l_y[i], p_prim_r_y[i], p_rhs_l_y[i], p_rhs_r_y[i],
                            p_flux_c_y[i], p_flux_e_y[i], p_fder_c_y[i], p_rhs_y_0[i],
                            p_LU_y[i], p_slu_l_y[i], p_slu_r_y[i], p_matrix_l_y[i], p_matrix_r_y[i],
                            Nx, Ny, Nz )
    end

    -- Add z-direction flux derivative to RHS.
    __demand(__parallel)
    for i in pencil do
      add_zflux_der_to_rhs( p_cnsr_z[i], p_prim_c_z[i], p_prim_l_z[i], p_prim_r_z[i], p_rhs_l_z[i], p_rhs_r_z[i],
                            p_flux_c_z[i], p_flux_e_z[i], p_fder_c_z[i], p_rhs_z_0[i],
                            p_LU_z[i], p_slu_l_z[i], p_slu_r_z[i], p_matrix_l_z[i], p_matrix_r_z[i],
                            Nx, Ny, Nz )
    end

    -- Update solution in this substep.
    __demand(__parallel)
    for i in pencil do
      set_zero_cnsr( p_cnsr_y_1[i] )
    end
    __demand(__parallel)
    for i in pencil do
      add_value_cnsr( p_cnsr_y_1[i], p_cnsr_y[i], 1.0 )
    end
    __demand(__parallel)
    for i in pencil do
      add_value_cnsr( p_cnsr_y_1[i], p_rhs_y_0[i], dt )
    end

    -- Update the primitive variables.
    __demand(__parallel)
    for i in pencil do
      token += get_primitive_r(p_cnsr_y_1[i], p_prim_c_y[i])
    end

    --------------------------------------------------------------------------------------------
    -- Advance second sub-step.
    --------------------------------------------------------------------------------------------

    -- Set RHS to zero.
    __demand(__parallel)
    for i in pencil do
      set_zero_cnsr( p_rhs_y_1[i] )
    end 

    -- Add x-direction flux derivative to RHS.
    __demand(__parallel)
    for i in pencil do
      add_xflux_der_to_rhs( p_cnsr_x_1[i], p_prim_c_x[i], p_prim_l_x[i], p_prim_r_x[i], p_rhs_l_x[i], p_rhs_r_x[i],
                            p_flux_c_x[i], p_flux_e_x[i], p_fder_c_x[i], p_rhs_x_1[i],
                            p_LU_x[i], p_slu_l_x[i], p_slu_r_x[i], p_matrix_l_x[i], p_matrix_r_x[i],
                            Nx, Ny, Nz )
    end

    -- Add y-direction flux derivative to RHS.
    __demand(__parallel)
    for i in pencil do
      add_yflux_der_to_rhs( p_cnsr_y_1[i], p_prim_c_y[i], p_prim_l_y[i], p_prim_r_y[i], p_rhs_l_y[i], p_rhs_r_y[i],
                            p_flux_c_y[i], p_flux_e_y[i], p_fder_c_y[i], p_rhs_y_1[i],
                            p_LU_y[i], p_slu_l_y[i], p_slu_r_y[i], p_matrix_l_y[i], p_matrix_r_y[i],
                            Nx, Ny, Nz )
    end

    -- Add z-direction flux derivative to RHS.
    __demand(__parallel)
    for i in pencil do
      add_zflux_der_to_rhs( p_cnsr_z_1[i], p_prim_c_z[i], p_prim_l_z[i], p_prim_r_z[i], p_rhs_l_z[i], p_rhs_r_z[i],
                            p_flux_c_z[i], p_flux_e_z[i], p_fder_c_z[i], p_rhs_z_1[i],
                            p_LU_z[i], p_slu_l_z[i], p_slu_r_z[i], p_matrix_l_z[i], p_matrix_r_z[i],
                            Nx, Ny, Nz )
    end

    -- Update solution in this substep.
    __demand(__parallel)
    for i in pencil do
      set_zero_cnsr( p_cnsr_y_2[i] )
    end
    __demand(__parallel)
    for i in pencil do
      add_value_cnsr( p_cnsr_y_2[i], p_cnsr_y[i], 3.0/4.0 )
    end
    __demand(__parallel)
    for i in pencil do
      add_value_cnsr( p_cnsr_y_2[i], p_cnsr_y_1[i], 1.0/4.0 )
    end
    __demand(__parallel)
    for i in pencil do
      add_value_cnsr( p_cnsr_y_2[i], p_rhs_y_1[i], 1.0/4.0*dt )
    end

    -- Update the primitive variables.
    __demand(__parallel)
    for i in pencil do
      token += get_primitive_r(p_cnsr_y_2[i], p_prim_c_y[i])
    end
 
    --------------------------------------------------------------------------------------------
    -- Advance third sub-step.
    --------------------------------------------------------------------------------------------

    -- Set RHS to zero.
    __demand(__parallel)
    for i in pencil do
      set_zero_cnsr( p_rhs_y_2[i] )
    end 

    -- Add x-direction flux derivative to RHS.
    __demand(__parallel)
    for i in pencil do
      add_xflux_der_to_rhs( p_cnsr_x_2[i], p_prim_c_x[i], p_prim_l_x[i], p_prim_r_x[i], p_rhs_l_x[i], p_rhs_r_x[i],
                            p_flux_c_x[i], p_flux_e_x[i], p_fder_c_x[i], p_rhs_x_2[i],
                            p_LU_x[i], p_slu_l_x[i], p_slu_r_x[i], p_matrix_l_x[i], p_matrix_r_x[i],
                            Nx, Ny, Nz )
    end

    -- Add y-direction flux derivative to RHS.
    __demand(__parallel)
    for i in pencil do
      add_yflux_der_to_rhs( p_cnsr_y_2[i], p_prim_c_y[i], p_prim_l_y[i], p_prim_r_y[i], p_rhs_l_y[i], p_rhs_r_y[i],
                            p_flux_c_y[i], p_flux_e_y[i], p_fder_c_y[i], p_rhs_y_2[i],
                            p_LU_y[i], p_slu_l_y[i], p_slu_r_y[i], p_matrix_l_y[i], p_matrix_r_y[i],
                            Nx, Ny, Nz )
    end

    -- Add z-direction flux derivative to RHS.
    __demand(__parallel)
    for i in pencil do
      add_zflux_der_to_rhs( p_cnsr_z_2[i], p_prim_c_z[i], p_prim_l_z[i], p_prim_r_z[i], p_rhs_l_z[i], p_rhs_r_z[i],
                            p_flux_c_z[i], p_flux_e_z[i], p_fder_c_z[i], p_rhs_z_2[i],
                            p_LU_z[i], p_slu_l_z[i], p_slu_r_z[i], p_matrix_l_z[i], p_matrix_r_z[i],
                            Nx, Ny, Nz )
    end

    -- Update solution in this substep.
    __demand(__parallel)
    for i in pencil do
      self_multiply_cnsr( p_cnsr_y[i], 1.0/3.0 )
    end
    __demand(__parallel)
    for i in pencil do
      add_value_cnsr( p_cnsr_y[i], p_cnsr_y_2[i], 2.0/3.0 )
    end
    __demand(__parallel)
    for i in pencil do
      add_value_cnsr( p_cnsr_y[i], p_rhs_y_2[i], 2.0/3.0*dt )
    end

    -- Update the primitive variables.
    __demand(__parallel)
    for i in pencil do
      token += get_primitive_r(p_cnsr_y[i], p_prim_c_y[i])
    end

    --------------------------------------------------------------------------------------------
    -- Update time step and time.
    --------------------------------------------------------------------------------------------
    
    step = step + 1
    tsim += dt

    -- if config.fileIO then
    --   if vizcond then
    --     wait_for(IOtoken)
    --     IOtoken += write_primitive(r_prim_c, config.filename_prefix, vizcount)
    --     vizcount = vizcount + 1
    --     vizcond = false
    --     dt = problem.dt
    --   end
    --   if tsim + dt >= tviz*vizcount then
    --     dt = tviz * vizcount - tsim
    --     vizcond = true
    --   end
    -- end

    var TKE : double = 0.0
    __demand(__parallel)
    for i in pencil do
      TKE += problem.TKE(p_prim_c_y[i])
    end

    if (step-1)%(config.nstats*50) == 0 then
      c.printf("\n")
      c.printf("%6.6s |%12.12s |%12.12s |%12.12s |%12.12s |%12.12s |%12.12s\n", "Step","Time","Timestep","Min rho","Max rho","Min p","Max p")
      c.printf("-------|-------------|-------------|-------------|-------------|-------------|------------\n")
    end

    if (step-1)%config.nstats == 0 then
      c.printf("%6d |%12.4e |%12.4e |%12.4e |%12.4e |%12.4e |%12.4e\n", step, tsim, dt, 0.0, 0.0, 0.0, TKE/TKE0)
      -- c.printf("%6d |%12.4e |%12.4e |%12.4e |%12.4e |%12.4e |%12.4e\n", step, tsim, dt, min_rho_p(r_prim_c), max_rho_p(r_prim_c), min_p_p(r_prim_c), max_p_p(r_prim_c))
    end
  end
  
  wait_for(token)
  var t_simulation = c.legion_get_current_time_in_micros() - t_start
  
  var errors : double[5]
  for ierr = 0,5 do
    errors[ierr] = 0.0
  end
  for i in pencil do
    var perrors = problem.get_errors(p_coords_y[i], p_prim_c_y[i], tsim)
    for ierr = 0,5 do
      if perrors[ierr] > errors[ierr] then
        errors[ierr] = perrors[ierr]
      end
    end
  end

  c.printf("\n")
  c.printf("Error in rho = %g\n", errors[0])
  c.printf("Error in u   = %g\n", errors[1])
  c.printf("Error in v   = %g\n", errors[2])
  c.printf("Error in w   = %g\n", errors[3])
  c.printf("Error in p   = %g\n", errors[4])

  c.printf("\n")
  c.printf("Average time per time step = %12.5e\n", (t_simulation)*1e-6/step)
  
  -- Destroy SuperLU structs.
  if Nx >= 8 then
    __demand(__parallel)
    for i in pencil do
      superlu.destroy_superlu_vars( p_slu_l_x[i] )
    end
    __demand(__parallel)
    for i in pencil do
      superlu.destroy_superlu_vars( p_slu_r_x[i] )
    end
  end

  if Ny >= 8 then
    __demand(__parallel)
    for i in pencil do
      superlu.destroy_superlu_vars( p_slu_l_y[i] )
    end
    __demand(__parallel)
    for i in pencil do
      superlu.destroy_superlu_vars( p_slu_r_y[i] )
    end
  end

  if Nz >= 8 then
    __demand(__parallel)
    for i in pencil do
      superlu.destroy_superlu_vars( p_slu_l_z[i] )
    end
    __demand(__parallel)
    for i in pencil do
      superlu.destroy_superlu_vars( p_slu_r_z[i] )
    end
  end
end

if os.getenv('SAVEOBJ') == '1' then
  local root_dir = arg[0]:match(".*/") or "./"
  local superlu_root = os.getenv('SUPERLU_PATH') or "/opt/SuperLU_5.2.1"
  local link_flags = {"-L" .. root_dir, "-L" .. superlu_root, "-lsuperlu_mapper", "-lsuperlu_util", "-lsuperlu", "-lm", "-lblas"}
  regentlib.saveobj(main, "wchr", "executable", csuperlu_mapper.register_mappers, link_flags)
else
  regentlib.start(main, csuperlu_mapper.register_mappers)
end