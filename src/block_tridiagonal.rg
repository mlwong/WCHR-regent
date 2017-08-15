import "regent"

local lapack = terralib.includecstring [[
extern void dgetrf_(int* M, int *N, double* A, int* lda, int* IPIV, int* INFO);

extern void dgetri_(int* N, double* A, int* lda, int* IPIV, double* WORK, int* lwork, int* INFO);
]]

if os.execute("bash -c \"[ `uname` == 'Darwin' ]\"") == 0 then
  terralib.linklibrary("libblas.dylib")
  terralib.linklibrary("liblapack.dylib")
else
  terralib.linklibrary("libblas.so")
  terralib.linklibrary("liblapack.so")
end

local c       = regentlib.c
local cmath   = terralib.includec("math.h")
local cstdlib = terralib.includec("stdlib.h")

require("fields")
require("SOE")
local problem = require("problem")

fspace coeffs {
  _0 : double,
  _1 : double,
  _2 : double,
  _3 : double,
  _4 : double,
}

local periodic_x = problem.periodic_x

-- All matrices here are in Fortran order

-- terra get_Rinv( rho : double, sos : double, Rinv : &double )
--   Rinv[0 + 3*0] = 0.; Rinv[0 + 3*1] = -0.5*rho*sos; Rinv[0 + 3*2] = 0.5;
--   Rinv[1 + 3*0] = 1.; Rinv[1 + 3*1] = 0.;           Rinv[1 + 3*2] = -1./(sos*sos);
--   Rinv[2 + 3*0] = 0.; Rinv[2 + 3*1] =  0.5*rho*sos; Rinv[2 + 3*2] = 0.5;
-- end

local terra multiply_diagonal_l( matrix : &double, d0 : double, d1 : double, d2 : double )
  matrix[0 + 3*0] = d0*matrix[0 + 3*0]; matrix[0 + 3*1] = d0*matrix[0 + 3*1]; matrix[0 + 3*2] = d0*matrix[0 + 3*2];
  matrix[1 + 3*0] = d1*matrix[1 + 3*0]; matrix[1 + 3*1] = d1*matrix[1 + 3*1]; matrix[1 + 3*2] = d1*matrix[1 + 3*2];
  matrix[2 + 3*0] = d2*matrix[2 + 3*0]; matrix[2 + 3*1] = d2*matrix[2 + 3*1]; matrix[2 + 3*2] = d2*matrix[2 + 3*2];
end

local terra multiply_diagonal_r( matrix : &double, d0 : double, d1 : double, d2 : double )
  matrix[0 + 3*0] = d0*matrix[0 + 3*0]; matrix[0 + 3*1] = d1*matrix[0 + 3*1]; matrix[0 + 3*2] = d2*matrix[0 + 3*2];
  matrix[1 + 3*0] = d0*matrix[1 + 3*0]; matrix[1 + 3*1] = d1*matrix[1 + 3*1]; matrix[1 + 3*2] = d2*matrix[1 + 3*2];
  matrix[2 + 3*0] = d0*matrix[2 + 3*0]; matrix[2 + 3*1] = d1*matrix[2 + 3*1]; matrix[2 + 3*2] = d2*matrix[2 + 3*2];
end

local terra mult_matrix_vector( matrix : &double, vector : &double )
  var output : double[3]

  output[0] = matrix[0 + 3*0]*vector[0] + matrix[0 + 3*1]*vector[1] + matrix[0 + 3*2]*vector[2]
  output[1] = matrix[1 + 3*0]*vector[0] + matrix[1 + 3*1]*vector[1] + matrix[1 + 3*2]*vector[2]
  output[2] = matrix[2 + 3*0]*vector[0] + matrix[2 + 3*1]*vector[1] + matrix[2 + 3*2]*vector[2]

  return output
end

local terra mult_matrix_matrix( matrix1 : &double, matrix2 : &double, output : &double )
  -- var output : double[9]

  for i = 0,3 do
    for j = 0,3 do
      output[i+3*j] = 0.
      for k = 0,3 do
        output[i+3*j] = output[i+3*j] + matrix1[i+3*k] * matrix2[k+3*j]
      end
    end
  end 

  -- return output
end

local terra invert_matrix( matrix : &double )
  var ipiv  : int[3]
  var lwork : int[1]
  var work  : double[9]
  var info  : int[1]
  var N     : int[1]

  N[0] = 3
  lwork[0] = 9

  lapack.dgetrf_(N,N,matrix,N,ipiv,info);
  regentlib.assert(info[0] == 0, "DGETRF did not work as expected. Check for errors.")

  lapack.dgetri_(N,matrix,N,ipiv,work,lwork,info);
  regentlib.assert(info[0] == 0, "DGETRI did not work as expected. Check for errors.")
end

local terra print_vector( vector : &double )

  for i = 0,3 do
    c.printf(" %11.8f ", vector[i])
    c.printf("\n")
  end
end

local terra print_matrix( matrix : &double )

  for i = 0,3 do
    for j = 0,3 do
	  c.printf(" %11.8f ", i, j, matrix[i + 3*j])
    end
    c.printf("\n")
  end
  c.printf("\n")
end

local terra random_number()
  return ( [double](cstdlib.rand()) / [double](cstdlib.RAND_MAX + 1.) )
end

local terra axpby( x : &double, y : &double, a : double, b : double, N : int )
  for i = 0,N do
    x[i] = a*x[i] + b*y[i]
  end
end

task solve_block_tridiagonal_x( alpha   : region( ispace(int3d), coeffs ),
                                beta    : region( ispace(int3d), coeffs ),
                                gamma   : region( ispace(int3d), coeffs ),
                                rho_avg : region( ispace(int3d), double ),
                                sos_avg : region( ispace(int3d), double ),
                                sol     : region( ispace(int3d), primitive ),
                                d       : region( ispace(int3d), &double ),
                                Uinv    : region( ispace(int3d), &double ) )
where
  reads(alpha, beta, gamma, rho_avg, sos_avg, sol, d, Uinv), writes(sol, d, Uinv, beta)
do
  var bounds = sol.ispace.bounds
  var N : int = bounds.hi.x + 1
  if periodic_x then
    N = bounds.hi.x -- Don't solve for last edge if periodic
  end

  for k = bounds.lo.z, bounds.hi.z+1 do
    for j = bounds.lo.y, bounds.hi.y+1 do

      if periodic_x then
        -- If periodic, make correction for Sherman-Morrison
        beta[{0,j,k}]._0 = beta[{0,j,k}]._0 + alpha[{0,j,k}]._0
        beta[{0,j,k}]._1 = beta[{0,j,k}]._1 + alpha[{0,j,k}]._1
        beta[{0,j,k}]._4 = beta[{0,j,k}]._4 + alpha[{0,j,k}]._4

        beta[{N-1,j,k}]._0 = beta[{N-1,j,k}]._0 + gamma[{N-1,j,k}]._0
        beta[{N-1,j,k}]._1 = beta[{N-1,j,k}]._1 + gamma[{N-1,j,k}]._1
        beta[{N-1,j,k}]._4 = beta[{N-1,j,k}]._4 + gamma[{N-1,j,k}]._4
      end

      -- Forward elimination
      get_Rinv( rho_avg[{0,j,k}], sos_avg[{0,j,k}], d[{0,j,k}] )
      multiply_diagonal_l( d[{0,j,k}], beta[{0,j,k}]._0, beta[{0,j,k}]._1, beta[{0,j,k}]._4 )
      invert_matrix( d[{0,j,k}] )

      sol[{0,j,k}].rho = -sol[{0,j,k}].rho
      sol[{0,j,k}].u   = -sol[{0,j,k}].u
      sol[{0,j,k}].p   = -sol[{0,j,k}].p

      if periodic_x then
        get_Rinv( rho_avg[{0,j,k}], sos_avg[{0,j,k}], Uinv[{0,j,k}] )
        multiply_diagonal_l( Uinv[{0,j,k}], alpha[{0,j,k}]._0, alpha[{0,j,k}]._1, alpha[{0,j,k}]._4 )
      end

      for i = 1,N do
        var Rinv_i : double[9]
        get_Rinv( rho_avg[{i,j,k}], sos_avg[{i,j,k}], Rinv_i ) -- Get Rinv at i

        var mat : double[9]
        mult_matrix_matrix( Rinv_i, d[{i-1,j,k}], mat )
        multiply_diagonal_l( mat, alpha[{i,j,k}]._0, alpha[{i,j,k}]._1, alpha[{i,j,k}]._4 )

        var gammaRinv_im1 : double[9]
        get_Rinv( rho_avg[{i-1,j,k}], sos_avg[{i-1,j,k}], gammaRinv_im1 ) -- Get Rinv at i-1
        multiply_diagonal_l( gammaRinv_im1, gamma[{i-1,j,k}]._0, gamma[{i-1,j,k}]._1, gamma[{i-1,j,k}]._4 )

        multiply_diagonal_l( Rinv_i, beta[{i,j,k}]._0, beta[{i,j,k}]._1, beta[{i,j,k}]._4 )

        mult_matrix_matrix( mat, gammaRinv_im1, d[{i,j,k}] )
        axpby( d[{i,j,k}], Rinv_i, -1., 1., 9 ) -- Delta_i = beta_i - alpha_i Delta_i gamma_i-1
        invert_matrix( d[{i,j,k}] )

        var prim : double[3] = array( sol[{i-1,j,k}].rho, sol[{i-1,j,k}].u, sol[{i-1,j,k}].p )
        var cprime = mult_matrix_vector( mat, prim )
        sol[{i,j,k}].rho = -sol[{i,j,k}].rho - cprime[0]
        sol[{i,j,k}].u   = -sol[{i,j,k}].u   - cprime[1]
        sol[{i,j,k}].p   = -sol[{i,j,k}].p   - cprime[2]

        if periodic_x then
          mult_matrix_matrix( mat, Uinv[{i-1,j,k}], Uinv[{i,j,k}] )
          multiply_diagonal_l( Uinv[{i,j,k}], -1., -1., -1. )
        end
      end

      if periodic_x then
        var Rinv : double[9]
        get_Rinv( rho_avg[{N-1,j,k}], sos_avg[{N-1,j,k}], Rinv ) -- Get Rinv
        multiply_diagonal_l( Rinv, gamma[{N-1,j,k}]._0, gamma[{N-1,j,k}]._1, gamma[{N-1,j,k}]._4 )
        axpby( Uinv[{N-1,j,k}], Rinv, 1., -1., 9 )
      end

      -- Back substitution
      var prim : double[3] = array( sol[{N-1,j,k}].rho, sol[{N-1,j,k}].u, sol[{N-1,j,k}].p )
      var cprime = mult_matrix_vector( d[{N-1,j,k}], prim )
      sol[{N-1,j,k}].rho = - cprime[0]
      sol[{N-1,j,k}].u   = - cprime[1]
      sol[{N-1,j,k}].p   = - cprime[2]

      if periodic_x then
        var tmp : double[9]
        mult_matrix_matrix( d[{N-1,j,k}], Uinv[{N-1,j,k}], tmp )
        for ii = 0,9 do
          (Uinv[{N-1,j,k}])[ii] = -tmp[ii]
        end
      end

      for i = N-1,0,-1 do
        var gammaRinv_im1 : double[9]
        get_Rinv( rho_avg[{i-1,j,k}], sos_avg[{i-1,j,k}], gammaRinv_im1 ) -- Get Rinv at i-1
        multiply_diagonal_l( gammaRinv_im1, gamma[{i-1,j,k}]._0, gamma[{i-1,j,k}]._1, gamma[{i-1,j,k}]._4 )

        prim = array( sol[{i,j,k}].rho, sol[{i,j,k}].u, sol[{i,j,k}].p )
        cprime = mult_matrix_vector( gammaRinv_im1, prim )    

        prim = array( sol[{i-1,j,k}].rho, sol[{i-1,j,k}].u, sol[{i-1,j,k}].p )
        axpby( prim, cprime, 1., 1., 3 )

        cprime = mult_matrix_vector( d[{i-1,j,k}], prim )
        sol[{i-1,j,k}].rho = - cprime[0]
        sol[{i-1,j,k}].u   = - cprime[1]
        sol[{i-1,j,k}].p   = - cprime[2]

        if periodic_x then
          var tmp : double[9]
          mult_matrix_matrix( gammaRinv_im1, Uinv[{i,j,k}], tmp )
          axpby( tmp, Uinv[{i-1,j,k}], -1., -1., 9 )
          mult_matrix_matrix( d[{i-1,j,k}], tmp, Uinv[{i-1,j,k}] )
        end -- periodic
      end

      -- Sherman-Morrison correction
      if periodic_x then
        var M : double[9] = array(1., 0., 0., 0., 1., 0., 0., 0., 1.) -- Identity matrix
        axpby( M, Uinv[{0,j,k}],   1., 1., 9 )
        axpby( M, Uinv[{N-1,j,k}], 1.,-1., 9 )
        invert_matrix( M )
        prim = array( sol[{0,j,k}].rho - sol[{N-1,j,k}].rho, sol[{0,j,k}].u - sol[{N-1,j,k}].u, sol[{0,j,k}].p - sol[{N-1,j,k}].p )
        var corrfact : double[3] = mult_matrix_vector( M, prim )

        for i = 0,N do
          cprime = mult_matrix_vector( Uinv[{i,j,k}], corrfact )
          sol[{i,j,k}].rho = sol[{i,j,k}].rho - cprime[0]
          sol[{i,j,k}].u   = sol[{i,j,k}].u   - cprime[1]
          sol[{i,j,k}].p   = sol[{i,j,k}].p   - cprime[2]
        end

        -- Copy last edge if periodic
        sol[{N,j,k}].rho = sol[{0,j,k}].rho
        sol[{N,j,k}].u   = sol[{0,j,k}].u
        sol[{N,j,k}].p   = sol[{0,j,k}].p
      end

    end
  end

end

terra allocate_double( size : int64 )
  return [&double] ( c.malloc( size * sizeof(double) ) )
end

terra deallocate_double( pointer : &double )
  c.free(pointer)
end
-- 
-- task main()
-- 
--   var nx : int = 8
--   var ny : int = 8
--   var nz : int = 8
-- 
--   var alpha = region( ispace(int3d, {x = nx, y = ny, z = nz}), coeffs )
--   var beta  = region( ispace(int3d, {x = nx, y = ny, z = nz}), coeffs )
--   var gamma = region( ispace(int3d, {x = nx, y = ny, z = nz}), coeffs )
-- 
--   fill(alpha.{_0,_1,_4}, 3./16.)
--   fill(beta.{_0,_1,_4}, 5./8.)
--   fill(gamma.{_0,_1,_4}, 3./16.)
-- 
--   var sol = region( ispace(int3d, {x = nx, y = ny, z = nz}), primitive )
--   for i in sol do
--     sol[i].rho = random_number()
--     sol[i].u   = random_number()
--     sol[i].p   = random_number()
--   end
--   print_sol( sol )
-- 
--   var rho_avg = region( ispace(int3d, {x = nx, y = ny, z = nz}), double )
--   var sos_avg = region( ispace(int3d, {x = nx, y = ny, z = nz}), double )
--   for i in rho_avg do
--     rho_avg[i] = 0.5 + 0.5*random_number()
--     sos_avg[i] = 0.5 + 0.5*random_number()
--   end
-- 
--   c.printf("rho_avg = numpy.array([ ")
--   for i = 0,nx do
--     c.printf(" %20.16e, ", rho_avg[{i,3,6}])
--   end
--   c.printf("\b\b])\n\n")
-- 
--   c.printf("sos_avg = numpy.array([ ")
--   for i = 0,nx do
--     c.printf(" %20.16e, ", sos_avg[{i,3,6}])
--   end
--   c.printf("\b\b])\n\n")
-- 
--   var d = region( ispace(int3d, {x = nx, y = ny, z = nz}), &double )
--   for i in d do
--     d[i] = allocate_double(9)
--   end
-- 
--   var Uinv = region( ispace(int3d, {x = nx, y = ny, z = nz}), &double )
--   for i in Uinv do
--     Uinv[i] = allocate_double(9)
--   end
-- 
--   solve_block_tridiagonal( alpha, beta, gamma, rho_avg, sos_avg, sol, d, Uinv )
--   print_sol( sol )
-- end
-- 
-- regentlib.start(main)
