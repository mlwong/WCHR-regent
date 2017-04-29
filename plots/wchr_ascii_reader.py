import glob
import numpy

import matplotlib
from matplotlib import cm
from mpl_toolkits.mplot3d import Axes3D
import matplotlib.pyplot as plt

class wchr_reader:
    """
    Class to read in parallel ASCII data generated by the WCHR Regent code
    """

    def __init__(self, filename_prefix):
        """
        Constructor of the WCHR reader class
        """

        self.filename_prefix = filename_prefix
        self.coord_files = glob.glob(filename_prefix + 'coords_*.dat')

        files = glob.glob(filename_prefix + '[0-9]*.dat')

        self.steps = steps = set([])
        self.prow  = 0
        self.pcol  = 0
        for f in files:
            step = int(f[len(filename_prefix):len(filename_prefix)+4])
            if not (step in steps):
                steps.add(step)

            st  = f[len(filename_prefix):]
            ind = st.find('px')
            row = int(st[ind+2:ind+6])
            if row > self.prow:
                self.prow = row
            ind = st.find('pz')
            col = int(st[ind+2:ind+6])
            if col > self.pcol:
                self.pcol = col

        self.prow += 1
        self.pcol += 1

        self.pencil_lo    = numpy.zeros((self.prow,self.pcol,2), dtype=int)
        self.pencil_hi    = numpy.zeros((self.prow,self.pcol,2), dtype=int)
        self.domain_size  = numpy.zeros(3, dtype=int)

        for row in range(self.prow):
            for col in range(self.pcol):
                coordfile = filename_prefix + ('coords_px%04d_pz%04d.dat' % (row, col))

                f = open(coordfile)

                line = f.readline().split()
                self.pencil_lo[row,col,1] = int(line[0])
                self.pencil_lo[row,col,0] = int(line[2])

                line = f.readline().split()
                self.pencil_hi[row,col,1] = int(line[0]) + 1
                self.pencil_hi[row,col,0] = int(line[2]) + 1

                if self.domain_size[1] == 0:
                    self.domain_size[1] = int(line[1]) + 1

                assert(self.domain_size[1] == int(line[1]) + 1, "Data is invalid. Unequal domain sized in the y direction for different pencils!")

                f.close()

        self.domain_size[0] = self.pencil_hi[-1,-1,0]
        self.domain_size[2] = self.pencil_hi[-1,-1,1]

    def read_x_coord(self):
        """
        Method to read in the full domain's X coordinates
        """
        self.x_c = numpy.zeros((self.domain_size[0], self.domain_size[1], self.domain_size[2] ))

        for row in range(self.prow):
            for col in range(self.pcol):
                coordfile = self.filename_prefix + ('coords_px%04d_pz%04d.dat' % (row, col))

                this_x = numpy.loadtxt(coordfile, skiprows=2, unpack=True, usecols=(0,))

                lo = self.pencil_lo[row,col]
                hi = self.pencil_hi[row,col]
                self.x_c[lo[0]:hi[0], :, lo[1]:hi[1]] = this_x.reshape((hi[0]-lo[0], self.domain_size[1], hi[1]-lo[1]))


    def read_y_coord(self):
        """
        Method to read in the full domain's Y coordinates
        """
        self.y_c = numpy.zeros((self.domain_size[0], self.domain_size[1], self.domain_size[2] ))

        for row in range(self.prow):
            for col in range(self.pcol):
                coordfile = self.filename_prefix + ('coords_px%04d_pz%04d.dat' % (row, col))

                this_y = numpy.loadtxt(coordfile, skiprows=2, unpack=True, usecols=(1,))

                lo = self.pencil_lo[row,col]
                hi = self.pencil_hi[row,col]
                self.y_c[lo[0]:hi[0], :, lo[1]:hi[1]] = this_y.reshape((hi[0]-lo[0], self.domain_size[1], hi[1]-lo[1]))


    def read_z_coord(self):
        """
        Method to read in the full domain's Z coordinates
        """
        self.z_c = numpy.zeros((self.domain_size[0], self.domain_size[1], self.domain_size[2] ))

        for row in range(self.prow):
            for col in range(self.pcol):
                coordfile = self.filename_prefix + ('coords_px%04d_pz%04d.dat' % (row, col))

                this_z = numpy.loadtxt(coordfile, skiprows=2, unpack=True, usecols=(2,))

                lo = self.pencil_lo[row,col]
                hi = self.pencil_hi[row,col]
                self.z_c[lo[0]:hi[0], :, lo[1]:hi[1]] = this_z.reshape((hi[0]-lo[0], self.domain_size[1], hi[1]-lo[1]))


    def read_variable(self, var, step):
        """
        Method to read in the full domain's data for variable var at vizdump step
        """
        v = numpy.zeros((self.domain_size[0], self.domain_size[1], self.domain_size[2] ))

        assert(step in self.steps, "Step to read in is not available in the dataset.")

        inds = {'rho' : 0, 'u' : 1, 'v' : 2, 'w' : 3, 'p' : 4}
        ind = inds[var]

        for row in range(self.prow):
            for col in range(self.pcol):
                filename = self.filename_prefix + ('%04d_px%04d_pz%04d.dat' % (step, row, col))

                this_var = numpy.loadtxt(filename, skiprows=2, unpack=True, usecols=(ind,))

                lo = self.pencil_lo[row,col]
                hi = self.pencil_hi[row,col]
                v[lo[0]:hi[0], :, lo[1]:hi[1]] = this_var.reshape((hi[0]-lo[0], self.domain_size[1], hi[1]-lo[1]))

        return v

    def plot(self, var, index):
        zind = index[0]
        yind = index[1]
        xind = index[2]

        norm = matplotlib.colors.Normalize(vmin=var.min(), vmax=var.max())
        cmap = cm.ScalarMappable(norm=norm, cmap=cm.viridis)
        cmap.set_array(var)

        fig = plt.figure()
        ax = fig.gca(projection='3d')

        surf_z = ax.plot_surface(self.x_c[zind,:,:], self.y_c[zind,:,:], self.z_c[zind,:,:], facecolors=cmap.to_rgba(var[zind,:,:]), linewidth=0)
        surf_y = ax.plot_surface(self.x_c[:,yind,:], self.y_c[:,yind,:], self.z_c[:,yind,:], facecolors=cmap.to_rgba(var[:,yind,:]), linewidth=0)
        surf_x = ax.plot_surface(self.x_c[:,:,xind], self.y_c[:,:,xind], self.z_c[:,:,xind], facecolors=cmap.to_rgba(var[:,:,xind]), linewidth=0)

        fig.colorbar(cmap)
        plt.show()
