import "regent"

local superlu = {}
do
  local superlu_library = "-lsuperlu"
  local superlu_include_dir = "/opt/SuperLU_5.2.1"
  local root_dir = arg[0]:match(".*/") or "./"
  local superlu_util_cc = root_dir .. "superlu_util.c"
  superlu_util_so = os.tmpname() .. ".so"
  local cc = os.getenv('CC') or 'cc'
  local cc_flags = "-O3 -Wall -Werror -std=c99"
  cc_flags = cc_flags .. " -I" .. superlu_include_dir
  local is_darwin = os.execute('test "$(uname)" = Darwin') == 0
  if is_darwin then
    cc_flags =
      (cc_flags ..
         " -dynamiclib -single_module -undefined dynamic_lookup -fPIC")
  else
    cc_flags = cc_flags .. " -shared -fPIC"
  end
  cc_flags = cc_flags .. " -lm -lblas " .. superlu_library 

  local cmd = (cc .. " " .. cc_flags .. " " .. superlu_util_cc .. " -o " .. superlu_util_so)
  -- print(cmd)

  if os.execute(cmd) ~= 0 then
    print("Error: failed to compile " .. superlu_util_cc)
    assert(false)
  end
  terralib.linklibrary(superlu_util_so)
  if is_darwin then
    terralib.linklibrary("libsuperlu.dylib")
  else
    terralib.linklibrary("libsuperlu.so")
  end
  superlu.c = terralib.includec("superlu_util.h", {"-I", root_dir, "-I", superlu_include_dir })
end

local c = regentlib.c

struct superlu.CSR_matrix {
  nzval  : &double,
  colind : &int,
  rowptr : &int,
  nnz    : int64,
}

terra superlu.initialize_matrix( alpha  : double,
                                 beta   : double,
                                 nx     : int64,
                                 ny     : int64,
                                 nz     : int64 )
  var matrix : superlu.CSR_matrix

  var Nsize : int64 = nx*ny*nz
  matrix.nnz = 5*Nsize
  matrix.rowptr = [&int] ( c.malloc ( (Nsize+1) * sizeof(int) ) )
  matrix.colind = [&int] ( c.malloc ( matrix.nnz * sizeof(int) ) )
  matrix.nzval  = [&double] ( c.malloc ( matrix.nnz * sizeof(double) ) )

  var Avals : double[5]
  Avals[0] = beta
  Avals[1] = alpha
  Avals[2] = 1.0
  Avals[3] = alpha
  Avals[4] = beta

  var counter : int64 = 0
  matrix.rowptr[0] = counter

  for row = 0, nx do
    for iy = 0, ny do
      for iz = 0, nz do
        for j = 0, 5 do
          var col : int = row + j - 2
          var gcol : int64 = iz + nz*iy + ny*nz*((col + nx)%nx)
          matrix.colind[counter] = gcol
          matrix.nzval [counter] = Avals[j]
          counter = counter + 1
        end
        var grow : int64 = iz + nz*iy + ny*nz*row
        matrix.rowptr[grow+1] = matrix.rowptr[grow] + 5
      end
    end
  end

  return matrix
end

local terra get_base_pointer_1d(pr   : c.legion_physical_region_t,
                                fid  : c.legion_field_id_t,
                                rect : c.legion_rect_1d_t)
  var subrect : c.legion_rect_1d_t
  var offsets : c.legion_byte_offset_t[1]
  var accessor = c.legion_physical_region_get_field_accessor_generic(pr, fid)
  var base_pointer =
    [&superlu.c.superlu_vars_t](c.legion_accessor_generic_raw_rect_ptr_1d(
      accessor, rect, &subrect, &(offsets[0])))
  c.legion_accessor_generic_destroy(accessor)
  return base_pointer
end

local terra get_base_pointer(pr   : c.legion_physical_region_t[1],
                             fid  : c.legion_field_id_t[1],
                             rect : c.legion_rect_3d_t)
  var subrect : c.legion_rect_3d_t
  var offsets : c.legion_byte_offset_t[3]
  var accessor = c.legion_physical_region_get_field_accessor_generic(pr[0], fid[0])
  var base_pointer =
    [&double](c.legion_accessor_generic_raw_rect_ptr_3d(
      accessor, rect, &subrect, &(offsets[0])))
  c.legion_accessor_generic_destroy(accessor)
  return base_pointer
end

terra superlu.initialize_superlu_vars( matrix : superlu.CSR_matrix,
                                       Nsize  : int64,
                                       pr1    : c.legion_physical_region_t[1],
                                       fid1   : c.legion_field_id_t[1],
                                       pr2    : c.legion_physical_region_t[1],
                                       fid2   : c.legion_field_id_t[1],
                                       rect   : c.legion_rect_3d_t )
  var b = get_base_pointer(pr1, fid1, rect)
  var x = get_base_pointer(pr2, fid2, rect)
  var vars : superlu.c.superlu_vars_t = superlu.c.initialize_superlu_vars(matrix.nzval, matrix.colind, matrix.rowptr, Nsize, matrix.nnz, b, x)
  return vars
end

terra superlu.MatrixSolve( pr1    : c.legion_physical_region_t[1],
                           fid1   : c.legion_field_id_t[1],
                           pr2    : c.legion_physical_region_t[1],
                           fid2   : c.legion_field_id_t[1],
                           rect   : c.legion_rect_3d_t,
                           matrix : superlu.CSR_matrix,
                           nx     : int,
                           ny     : int,
                           nz     : int,
                           prv    : c.legion_physical_region_t,
                           fidv   : c.legion_field_id_t,
                           rectv  : c.legion_rect_1d_t )
  var b = get_base_pointer(pr1, fid1, rect)
  var x = get_base_pointer(pr2, fid2, rect)
  var vars = get_base_pointer_1d(prv, fidv, rectv)
  superlu.c.MatrixSolve(b, x, matrix.nzval, nx, ny, nz, vars)
end

return superlu
