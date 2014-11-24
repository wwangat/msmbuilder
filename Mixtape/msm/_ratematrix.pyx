#cython: boundscheck=False, cdivision=True, wraparound=False
# Author: Robert McGibbon <rmcgibbo@gmail.com>
# Contributors:
# Copyright (c) 2014, Stanford University
# All rights reserved.

# Mixtape is free software: you can redistribute it and/or modify
# it under the terms of the GNU Lesser General Public License as
# published by the Free Software Foundation, either version 2.1
# of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with Mixtape. If not, see <http://www.gnu.org/licenses/>.
"""Implementation of the log-likelihood function and gradient for a
continuous-time reversible Markov model sampled at a regular interval.

Theory
------

Consider an `n`-state time-homogeneous Markov process, `X(t)` At time `t`, the
`n`-vector P(t) = `Pr(X(t) = i)` is probability that the system is in each of
the `n` states. These probabilities evolve forward in time, governed by
an `n x n` transition rate matrix `K` ::

    dP(t)/dt = P(t) * K

The solution is ::

    P(t) = exp(tK) * P(0)

In other words, the state-to-state lag-\tau transition probability is ::

    P[ X(t+\tau) = j | X(t) = i ] = exp(\tau K)_{ij}

For this model, we observe the evolution of one or more chains, `X(t)` at a
regular interval, `\tau`. Let `C_{ij}` be the number of times the chain was
observed at state `i` at time `t` and at state `j` at time `t+\tau` (the number
of observed transition counts). Suppose that `K` depends on a length-`b`
parameter vector, `\theta`. The log-likelihood is ::

  L(\theta) = \sum_{ij} C_{ij} log(exp(\tau K(\theta))_{ij})

The function :func:`loglikelihood` computes this log-likelihood and and gradient
of the log-likelihood with respect to `\theta`.

Parameterization
----------------
This code parameterizes K(\theta) such that K is constrained to satisfy
detailed-balance with respect to a stationary distribution, `pi`. For an
`n`-state model, `theta` is of length `n*(n-1)/2 + n`. The first `n*(n-1)/2`
elements of theta are the parameterize the symmetric rate matrix, S, and the
remaining `n` entries parameterize the stationary distribution. For n=3, the
function K(\theta) is shown below ::

  s_u   =  exp(\theta_u)                for  u = 0, 1, ..., n*(n-1)/2
  pi_i  =  exp(\theta_{i + n*(n-1)/2})  for  i = 0, 1, ..., n
  r_i   =  sqrt(pi_i)                   for  i = 0, 1, ..., n

     [[     k_00,     s0*(r0/r1),  s1*r(0/r2),  s2*(r0/r3)  ],
      [  s0*(r1/r0),     k_11,     s3*(r1/r2),  s4*(r1/r3)  ],
  K = [  s1*(r2/r0),  s3*(r2/r1),     k_22,     s5*(r2/r3)  ],
      [  s2*(r3/r0),  s4*(r3/r1),  s5*(r3/r2),      k_33    ]]

  where the diagonal elements `k_ii` are set such that the row sums of `K` are
  all zero, `k_{ii} = -\sum_{j != i} K_{ij}`

This form for `K` satisfies detailed balance by construction ::

  K_{ij} / K_{ji}  =  ri**2 / rj**2  =  pi_i / pi_j

Note that `K` is built from `exp(\theta)`. This parameterization makes
optimization easier, since it keeps the off-diagonal entries positive and the
diagonal entries negative.

Performance
-----------
This is pretty low-level cython code. Everything is explicitly typed, and
we use cython memoryviews. Using the wrappers from `cy_blas.pyx`, we make
direct calls to the FORTRAN BLAS matrix multiply using the function pointers
that scipy exposes.

There are assert statements which provide some clarity, but are slow.
They are compiled away by default using the CYTHON_WITHOUT_ASSERTIONS macro.
To enable them when compiling from source `python setup.py install` needs to
be run with the flag `--debug` on the command line.

References
----------
..[1] Kalbfleisch, J. D., and Jerald F. Lawless. "The analysis of panel data
under a Markov assumption." J. Am. Stat. Assoc. 80.392 (1985): 863-871.
"""

from __future__ import print_function
import numpy as np
from numpy import (zeros, allclose, array, real, ascontiguousarray, dot, diag)
import scipy.linalg
from scipy.linalg import blas, eig
from numpy cimport npy_intp
from libc.math cimport sqrt, log, exp
from libc.string cimport memset
from libc.stdlib cimport calloc, free

include "cy_blas.pyx"


cpdef buildK(double[::1] exptheta, npy_intp n, double[:, ::1] out):
    """Build the reversible rate matrix K from the free parameters, `\theta`

    Parameters
    ----------
    exptheta : [input], array of length = (n*(n-1)/2) + n
        The element-wise exponential of the free parameters, `\theta`.
    n : [input]
        The dimension
    out : [output], 2d array of shape = (n, n)
        The rate matrix is written into this array
    """
    assert out.shape[0] == n
    assert out.shape[1] == n
    assert exptheta.shape[0] == (n*(n-1)/2) + n
    cdef npy_intp i, j, u
    cdef double K_ij, K_ji, s_ij
    cdef npy_intp n_S_triu = (n*(n-1)/2)
    cdef double[::1] pi = exptheta[n_S_triu:]
    cdef double[::1] K_ii = <double[:n]>calloc(n, sizeof(double))

    u = 0
    for i in range(n):
        for j in range(i+1, n):
            s_ij = exptheta[u]
            K_ij = s_ij * sqrt(pi[i] / pi[j])
            K_ji = s_ij * sqrt(pi[j] / pi[i])
            out[i, j] = K_ij
            out[j, i] = K_ji
            K_ii[i] -= K_ij
            K_ii[j] -= K_ji
            u += 1

    for i in range(n):
        out[i, i] = K_ii[i]

    free(&K_ii[0])

    assert np.allclose(np.array(out).sum(axis=1), 0.0)
    assert np.allclose(scipy.linalg.expm(np.array(out)).sum(axis=1), 1)
    assert np.all(0 < scipy.linalg.expm(np.array(out)))
    assert np.all(1 > scipy.linalg.expm(np.array(out)))


cpdef dK_dtheta(double[::1] exptheta, npy_intp n, npy_intp u, double[:, ::1] out):
    """Derivative of the rate matrix, `K`, with respect to the free parameters,
    `\theta`, dK_ij / dtheta_u

    Parameters
    ----------
    exptheta : [input], array of length = (n*(n-1)/2) + n
        The element-wise exponential of the free parameters, `\theta`.
    n : [input]
        The dimension
    u : [input]
        The index of the element in theta to compute the derivative of K with
        respect to
    out : [output], array of shape (n, n)
        The output is written here, `out[i, j] = d(K_ij) / d(theta_u)`
    """
    # workspace of size (n)

    cdef npy_intp n_S_triu = (n*(n-1)/2)
    assert out.shape[0] == n
    assert out.shape[1] == n
    assert u >= 0 and u < n_S_triu + n
    assert exptheta.shape[0] == n_S_triu + n

    cdef npy_intp i, j
    cdef double dK_ij
    cdef double[::1] pi = exptheta[n_S_triu:]
    cdef double[::1] dK_ii

    if u < n_S_triu:
        # the perturbation is to the triu rate matrix
        # first, use the linear index, u, to get the (i,j)
        # indices of the symmetric rate matrix

        # E.g with the 4x4 upper-triangular matrix, we need
        # to get the (i,j) index of an element from its
        # linear index:
        #  [ 0  a0  a1  a2  a3 ]      0 -> (i=0,j=1)
        #  [ 0   0  a4  a5  a6 ]      1 -> (i=0,j=2)
        #  [ 0   0   0  a7  a8 ]      5 -> (i=1,j=3)
        #  [ 0   0   0   0  a9 ]            etc
        #  [ 0   0   0   0   0 ]
        # http://stackoverflow.com/a/27088560/1079728
        i = n - 2 - <int>(sqrt(-8*u + 4*n*(n-1)-7)/2.0 - 0.5)
        j = u + i + 1 - n*(n-1)/2 + (n-i)*((n-i)-1)/2

        s_ij = exptheta[u]
        dK_ij = s_ij * sqrt(pi[i] / pi[j])
        dK_ji = s_ij * sqrt(pi[j] / pi[i])

        out[i, j] = dK_ij
        out[j, i] = dK_ji
        out[i, i] = -dK_ij
        out[j, j] = -dK_ji

    else:
        # the perturbation is to the equilibrium distribution

        # `i` is now the index, in `pi`, of the perturbed element
        # of the equilibrium distribution
        i = u - n_S_triu
        dK_ii = <double[:n]>calloc(n, sizeof(double))

        for j in range(n):
            if j == i:
                continue

            if j > i:
                k = (n*(n-1)/2) - (n-i)*((n-i)-1)/2 + j - i - 1
            else:
                k = (n*(n-1)/2) - (n-j)*((n-j)-1)/2 + i - j - 1

            s_ij = exptheta[k]
            dK_ij = 0.5  * s_ij * sqrt(pi[i] / pi[j])
            dK_ji = -0.5 * s_ij * sqrt(pi[j] / pi[i])

            out[i, j] = dK_ij
            out[j, i] = dK_ji
            dK_ii[i] -= dK_ij
            dK_ii[j] -= dK_ji

        for i in range(n):
            out[i, i] = dK_ii[i]

        free(&dK_ii[0])


cdef dP_dtheta_terms(double[:, ::1] K, npy_intp n, double t):
    """Compute some of the terms required for d(exp(K))/d(theta). This
    includes the left and right eigenvectors of K, the eigenvalues, and
    the exp of the eigenvalues.

    Returns
    -------
    AL : array of shape = (n, n)
        The left eigenvectors of K
    AR : array of shape = (n, n)
        The right eigenvectors of K
    w : array of shape = (n,)
        The eigenvalues of K
    expw : array of shape = (n,)
        The exp of the eigenvalues of K
    """
    cdef npy_intp i
    w, AL, AR = scipy.linalg.eig(K, left=True, right=True)

    for i in range(n):
        # we need to ensure the proper normalization
        AL[:, i] /= dot(AL[:, i], AR[:, i])

    assert np.allclose(scipy.linalg.inv(AR).T, AL)

    AL = ascontiguousarray(real(AL))
    AR = ascontiguousarray(real(AR))
    w = ascontiguousarray(real(w))
    expwt = zeros(w.shape[0])
    for i in range(w.shape[0]):
        expwt[i] = exp(w[i]*t)

    return AL, AR, w, expwt


def loglikelihood(double[::1] theta, double[:, ::1] counts, npy_intp n, double t=1):
    """Log likelihood and gradient of the log likelihood of a continuous-time
    Markov model.

    Parameters
    ----------
    theta : array of shape = (n*(n-1)/2 + n)
        The free parameters of the model. See the section titled
        Parameterization.
    counts : array of shape = (n, n)
        The matrix of observed transition counts.
    n : int
        The size of `counts`
    t : double
        The lag time.

    Returns
    -------
    logl : double
        The log likelihood of the parameters.
    grad : array of shape = (n*(n-1)/2 + n)
        The gradient of the log-likelihood with respect to `\theta`
    """
    cdef npy_intp size = (n*(n-1)/2) + n
    if not (counts.shape[0] == n and counts.shape[1] == n):
        raise ValueError('counts must be n x n')
    if not theta.shape[0] == size:
        raise ValueError('theta must have length (n*(n-1)/2) + n')

    cdef npy_intp u, i, j
    cdef double grad_u, objective
    cdef double[::1] w, expwt, grad, exptheta
    cdef double[:, ::1] AL, AR, Gu, transmat, temp, Vu, dPu, dKu, K

    grad = zeros(size)
    exptheta = zeros(size)
    temp = zeros((n, n))
    K = zeros((n, n))
    Vu = zeros((n, n))
    dKu = zeros((n, n))
    for i in range(size):
        exptheta[i] = exp(theta[i])

    buildK(exptheta, n, K)
    AL, AR, w, expwt = dP_dtheta_terms(K, n, t)

    cdgemm_NN(AR, diag(expwt), temp)
    transmat = K
    cdgemm_NT(temp, AL, transmat)
    # Equivalent to  transmat = AR * diag(expw) * AL.T
    # placing the results in the same memory as K (destroying K)
    assert np.allclose(transmat, np.dot(np.dot(AR,  np.diag(expwt)), AL.T))

    for u in range(size):
        memset(&dKu[0, 0], 0, n*n * sizeof(double))
        dK_dtheta(exptheta, n, u, dKu)

        cdgemm_TN(AL, dKu, temp)
        Gu = dKu
        cdgemm_NN(temp, AR, Gu)
        # Equivalent to Gu = AL.T * dKu * AR
        # placing results in same memory as dKu (destroying dKu)

        for i in range(n):
            for j in range(n):
                if i != j:
                    Vu[i, j] = (expwt[i] - expwt[j]) / (w[i] - w[j]) * Gu[i, j]
                else:
                    Vu[i, i] = t * expwt[i] * Gu[i, j]

        cdgemm_NN(AR, Vu, temp)
        dPu = Vu
        cdgemm_NT(temp, AL, dPu)
        # Equivalent to dPu = AR * Vu * AL.T
        # placing results in same memory as Vu (destroying Vu)

        grad_u = 0
        for i in range(n):
            for j in range(n):
                grad_u += counts[i, j] * (dPu[i, j] / transmat[i, j])
        grad[u] = grad_u

    objective = 0
    for i in range(n):
        for j in range(n):
            objective += counts[i, j] * log(transmat[i, j])

    return objective, ascontiguousarray(grad)
