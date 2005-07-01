! $Id: dustdensity.f90,v 1.133 2005-07-01 03:53:08 mee Exp $

!  This module is used both for the initial condition and during run time.
!  It contains dndrhod_dt and init_nd, among other auxiliary routines.

!** AUTOMATIC CPARAM.INC GENERATION ****************************
! Declare (for generation of cparam.inc) the number of f array
! variables and auxiliary variables added by this module
!
! MVAR CONTRIBUTION 1
! MAUX CONTRIBUTION 0
!
! PENCILS PROVIDED glnnd,gmi,gmd,gnd,md,mi,nd,rhod
! PENCILS PROVIDED udgmi,udgmd,udglnnd,udgnd,glnnd2
! PENCILS PROVIDED sdglnnd,del2nd,del2lnnd,del6nd,del2md,del2mi
! PENCILS PROVIDED gndglnrho,glnndglnrho,del6lnnd
!
!***************************************************************

module Dustdensity

  use Cparam
  use Cdata
  use Messages
  use Dustvelocity

  implicit none

  include 'dustdensity.h'

  integer, parameter :: ndiffd_max=4  
  real, dimension(nx,ndustspec,ndustspec) :: dkern
  real :: diffnd=0.0,diffnd_hyper3=0.0,diffmd=0.0,diffmi=0.0
  real :: nd_const=1.,dkern_cst=1.,eps_dtog=0.,Sigmad=1.0
  real :: mdave0=1., adpeak=5e-4, supsatfac=1.,supsatfac1=1.
  real :: amplnd=1.,kx_nd=1.,ky_nd=1.,kz_nd=1.,widthnd=1.,Hnd=1.0,Hepsd=1.0
  integer :: ind_extra
  character (len=labellen), dimension (ninit) :: initnd='nothing'
  character (len=labellen), dimension (ndiffd_max) :: idiffd=''
  logical :: ludstickmax=.true.
  logical :: lcalcdkern=.true.,lkeepinitnd=.false.,ldustcontinuity=.true.
  logical :: ldustnulling=.false.,lupw_ndmdmi=.false.
  logical :: lnd_turb_diff=.false.,lmd_turb_diff=.false.,lmi_turb_diff=.false.
  logical :: ldeltaud_thermal=.true., ldeltaud_turbulent=.true.
  logical :: ldiffusion_dust=.true.
  logical :: lreinit_dustvars_ndneg=.false.
  logical :: ldiffd_simplified=.false.,ldiffd_dusttogasratio=.false.
  logical :: ldiffd_hyper3=.false.,ldiffd_hyper3lnnd=.false.

  namelist /dustdensity_init_pars/ &
      rhod0, initnd, eps_dtog, nd_const, dkern_cst, nd0, mdave0, Hnd, &
      adpeak, amplnd, kx_nd, ky_nd, kz_nd, widthnd, Hepsd, Sigmad, &
      lcalcdkern, supsatfac, lkeepinitnd, ldustcontinuity, lupw_ndmdmi, &
      ldeltaud_thermal, ldeltaud_turbulent, ldustdensity_log

  namelist /dustdensity_run_pars/ &
      rhod0, diffnd, diffnd_hyper3, diffmd, diffmi, &
      lcalcdkern, supsatfac, ldustcontinuity, ldustnulling, ludstickmax, &
      idiffd, lnd_turb_diff, lmd_turb_diff, lmi_turb_diff, &
      lreinit_dustvars_ndneg

  ! diagnostic variables (needs to be consistent with reset list below)
  integer :: idiag_ndmt=0,idiag_rhodmt=0,idiag_rhoimt=0
  integer :: idiag_ssrm=0,idiag_ssrmax=0
  integer, dimension(ndustspec) :: idiag_ndm=0,idiag_ndmin=0,idiag_ndmax=0
  integer, dimension(ndustspec) :: idiag_nd2m=0,idiag_rhodm=0,idiag_epsdrms=0

  contains

!***********************************************************************
    subroutine register_dustdensity()
!
!  Initialise variables which should know that we solve the
!  compressible hydro equations: ind; increase nvar accordingly.
!
!   4-jun-02/axel: adapted from hydro
!
      use Mpicomm, only: stop_it
      use Sub
      use General, only: chn
!
      logical, save :: first=.true.
      integer :: k
      character (len=4) :: sdust
!
      if (.not. first) call stop_it('register_dustdensity: called twice')
      first = .false.
!
      ldustdensity = .true.
!
!  Set ind to consecutive numbers nvar+1, nvar+2, ..., nvar+ndustspec
!
      do k=1,ndustspec
        ind(k)=nvar+k
      enddo
!
!  Increase nvar accordingly
!
      nvar=nvar+ndustspec
!
!  Allocate some f array variables for dust grain mass and ice density
!
      if (lmdvar .and. lmice) then   ! Both grain mass and ice density
        imd  = ind  + ndustspec 
        imi  = imd  + ndustspec 
        nvar = nvar + 2*ndustspec
      else if (lmdvar) then          ! Only grain mass
        imd  = ind  + ndustspec 
        nvar = nvar + ndustspec
      else if (lmice) then           ! Only ice density
        imi  = ind  + ndustspec
        nvar = nvar + ndustspec
      endif
!
!  Print some diagnostics
!
      do k=1,ndustspec
        if ((ip<=8) .and. lroot) then
          print*, 'register_dustdensity: k = ', k
          print*, 'register_dustdensity: nvar = ', nvar
          print*, 'register_dustdensity: ind = ', ind(k)
          if (lmdvar) print*, 'register_dustdensity: imd = ', imd(k)
          if (lmice)  print*, 'register_dustdensity: imi = ', imi(k)
        endif
!
!  Put variable name in array
!
        call chn(k,sdust)
        varname(ind(k)) = 'nd('//trim(sdust)//')'
        if (lmdvar) varname(imd(k)) = 'md('//trim(sdust)//')'
        if (lmice)  varname(imi(k)) = 'mi('//trim(sdust)//')'
      enddo
!
!  identify version number (generated automatically by CVS)
!
      if (lroot) call cvs_id( &
           "$Id: dustdensity.f90,v 1.133 2005-07-01 03:53:08 mee Exp $")
!
      if (nvar > mvar) then
        if (lroot) write(0,*) 'nvar = ', nvar, ', mvar = ', mvar
        call stop_it('register_dustdensity: nvar > mvar')
      endif
!
!  Ensure dust density variables are contiguous with dust velocity
!
      if ((iudz(ndustspec)+1) .ne. ind(1)) then
        call stop_it('register_dustdensity: uud and ind are NOT contiguous in the f-array - as required by copy_bcs_dust')
      endif
!
!  Write files for use with IDL
!
      do k=1,ndustspec
        call chn(k,sdust)
        if (ndustspec == 1) sdust = ''
        if (lroot) then
          if (maux == 0) then
            if (nvar < mvar) then
              write(4,*) ',nd'//trim(sdust)//' $'
              if (lmdvar) write(4,*) ',md'//trim(sdust)//' $'
              if (lmice)  write(4,*) ',mi'//trim(sdust)//' $'
            endif
            if (nvar == mvar) then
              write(4,*) ',nd'//trim(sdust)
              if (lmdvar) write(4,*) ',md'//trim(sdust)
              if (lmice)  write(4,*) ',mi'//trim(sdust)
            endif
          else
            write(4,*) ',nd'//trim(sdust)//' $'
            if (lmdvar) write(4,*) ',md'//trim(sdust)//' $'
            if (lmice)  write(4,*) ',mi'//trim(sdust)//' $'
          endif
          write(15,*) 'nd'//trim(sdust)//' = fltarr(mx,my,mz,1)*one'
          if (lmdvar) &
              write(15,*) 'md'//trim(sdust)//' = fltarr(mx,my,mz,1)*one'
          if (lmice) &
              write(15,*) 'mi'//trim(sdust)//' = fltarr(mx,my,mz,1)*one'
        endif
      enddo
!
    endsubroutine register_dustdensity
!***********************************************************************
    subroutine initialize_dustdensity()
!
!  Perform any post-parameter-read initialization i.e. calculate derived
!  parameters.
!
!  24-nov-02/tony: coded 
      use Mpicomm, only: stop_it
!
      integer :: i,j,k
      logical :: lnothing
!
      if (lroot) print*, 'initialize_dustdensity: '// &
          'ldustcoagulation,ldustcondensation =', &
          ldustcoagulation,ldustcondensation
!          
      if (ldustcondensation .and. .not. lpscalar) &
          call stop_it('initialize_dustdensity: ' // &
          'Dust growth only works with pscalar')
!
!  Special coagulation equation test cases require initialization of kernel
!
      do j=1,ninit
        select case (initnd(j))
        
        case('kernel_cst')
          dkern(:,:,:) = dkern_cst
          lcalcdkern = .false.

        case('kernel_lin')
          do i=1,ndustspec; do k=1,ndustspec
            dkern(:,i,k) = dkern_cst*(md(i)+md(k))
          enddo; enddo
          lcalcdkern = .false.

        endselect
      enddo
!
!  Initialize dust diffusion
!
      ldiffd_simplified=.false.
      ldiffd_dusttogasratio=.false.
      ldiffd_hyper3=.false.
!
      lnothing=.false.
!
      do i=1,ndiffd_max
        select case (idiffd(i))
        case ('simplified')
          if (lroot) print*,'dust diffusion: div(D*grad(nd))'
          ldiffd_simplified=.true.
        case ('dust-to-gas-ratio')
          if (lroot) print*,'dust diffusion: div(D*rho*grad(nd/rho))'
          ldiffd_dusttogasratio=.true.
        case ('hyper3')
          if (lroot) print*,'dust diffusion: (d^6/dx^6+d^6/dy^6+d^6/dz^6)nd'
          ldiffd_hyper3=.true.
        case ('hyper3lnnd')
          if (lroot) print*,'dust diffusion: (d^6/dx^6+d^6/dy^6+d^6/dz^6)lnnd'
          ldiffd_hyper3lnnd=.true.
        case ('')
          if (lroot .and. (.not. lnothing)) print*,'dust diffusion: nothing'
        case default
          if (lroot) print*, 'initialize_dustdensity: ', &
              'No such value for idiffd(',i,'): ', trim(idiffd(i))
          call stop_it('initialize_dustdensity')
        endselect
        lnothing=.true.
      enddo
!
      if ((ldiffd_simplified .or. ldiffd_dusttogasratio) .and. diffnd==0.0) then
        call warning('initialize_dustdensity', &
            'dust diffusion coefficient diffnd is zero!')
        ldiffd_simplified=.false.
        ldiffd_dusttogasratio=.false.
      endif
      if ( (ldiffd_hyper3.or.ldiffd_hyper3lnnd) .and. diffnd_hyper3==0.0) then
        call warning('initialize_dustdensity',
            'dust diffusion coefficient diffnd_hyper3 is zero!')
        ldiffd_hyper3=.false.
        ldiffd_hyper3lnnd=.false.
      endif
!
      if (ldiffd_hyper3 .and. ldustdensity_log .and. &
          .not. lglobal_nolog_density) then
         if (lroot) print*, 'initialize_dustdensity: must have '// &
             'global_nolog_density module for del6nd with '// &
             'logarithmic dust density'
         call stop_it('initialize_dustdensity')
      endif
!      
    endsubroutine initialize_dustdensity
!***********************************************************************
    subroutine init_nd(f)
!
!  initialise nd; called from start.f90
!
!  7-nov-01/wolf: coded
! 28-jun-02/axel: added isothermal
!
      use EquationOfState, only: cs0, gamma, gamma1
      use Global
      use Gravity
      use Initcond
      use IO
      use Mpicomm
      use Sub
!
      real, dimension (mx,my,mz,mvar+maux) :: f
! 
      real :: lnrho_z,Hrho,mdpeak,rhodmt=0.
      integer :: i,j,k,l
      logical :: lnothing
!
!  different initializations of nd (called from start).
!
      lnothing=.false.
      do j=1,ninit
        select case(initnd(j))
 
        case('nothing')
          if (lroot .and. .not. lnothing) print*, 'init_nd: nothing'
          lnothing=.true.
        case('zero')
          f(:,:,:,ind)=0.0
          if (lroot) print*,'init_nd: zero nd'
        case('const_nd')
          f(:,:,:,ind) = nd_const
          if (lroot) print*, 'init_nd: Constant dust number density'
        case('nd_sinx')
          do l=1,mx; f(l,:,:,ind(1)) = nd0 + amplnd*sin(kx_nd*x(l)); enddo
        case('nd_sinxsinysinz')
          do l=1,mx; do m=1,my; do n=1,mz
            f(l,m,n,ind(1)) = nd0 + &
                amplnd*sin(kx_nd*x(l))*sin(ky_nd*y(m))*sin(kz_nd*z(n))
          enddo; enddo; enddo
        case('gaussian_nd')
          if (lroot) print*, 'init_nd: Gaussian distribution in z'
          do n=n1,n2
            f(:,:,n,ind) = eps_dtog/(sqrt(2*pi)*Hnd)*exp(-z(n)**2/(2*Hnd**2))
          enddo
        case('gas_stratif_dustdrag')
          if (lroot) print*,'init_nd: extra gas stratification due to dust drag'
!          Hrho=cs0/nu_epicycle
          Hrho=1/sqrt(gamma)
          do n=n1,n2
            lnrho_z = alog( &
                eps_dtog/(sqrt(2*pi)*Hnd)*Hnd**2/(Hrho**2-Hnd**2)* &
                exp(-z(n)**2/(2*Hnd**2)) + &
                (1.0-eps_dtog*Hnd**2/(Hrho**2-Hnd**2))/(sqrt(2*pi)*Hrho)*&
                exp(-z(n)**2/(2*Hrho**2)) )
            if (ldensity_nolog) then
              f(:,:,n,ilnrho) = exp(lnrho_z)
            else 
              f(:,:,n,ilnrho) = lnrho_z
            endif
            if (lentropy) f(:,:,n,iss) = (1/gamma-1.0)*lnrho_z
          enddo
        case('hat3d')
          call hat3d(amplnd,f,ind(1),widthnd,kx_nd,ky_nd,kz_nd)
          f(:,:,:,ind(1)) = f(:,:,:,ind(1)) + nd_const
        case('first')
          print*, 'init_nd: All dust particles in first bin.'
          f(:,:,:,ind) = 0.
          f(:,:,:,ind(1)) = nd0
          if (eps_dtog/=0.) f(:,:,:,ind(1))= eps_dtog*exp(f(:,:,:,ilnrho))/md(1)
        case('firsttwo')
          print*, 'init_nd: All dust particles in first and second bin.'
          f(:,:,:,ind) = 0.
          do k=1,2
            f(:,:,:,ind(k)) = nd0/2
          enddo
        case('MRN77')   ! Mathis, Rumpl, & Nordsieck (1977)
          print*,'init_nd: Initial dust distribution of MRN77'
          do k=1,ndustspec
            mdpeak = 4/3.*pi*adpeak**3*rhods/unit_md
            if (md(k) <= mdpeak) then
              f(:,:,:,ind(k)) = ad(k)**(-3.5)*3/(4*pi*rhods)**(1/3.)* &
                  (mdplus(k)**(1/3.)-mdminus(k)**(1/3.))*unit_md**(1/3.)
            else
              f(:,:,:,ind(k)) = ad(k)**(-7)*3/(4*pi*rhods)**(1/3.)* &
                  (mdplus(k)**(1/3.)-mdminus(k)**(1/3.))*adpeak**(3.5)* &
                  unit_md**(1/3.)
            endif
            rhodmt = rhodmt + f(l1,m1,n1,ind(k))*md(k)
          enddo
    
          do k=1,ndustspec
            f(:,:,:,ind(k)) = &
                f(:,:,:,ind(k))*eps_dtog*exp(f(:,:,:,ilnrho))/(rhodmt*unit_md)
          enddo
          
        case('const_epsd')
          do k=1,ndustspec
            f(:,:,:,ind(k)) = eps_dtog*exp(f(:,:,:,ilnrho))/(md(k)*unit_md)
          enddo
        case('const_epsd_global')
          do l=1,mx
            do m=1,my
              do k=1,ndustspec
                f(l,m,:,ind(k)) = eps_dtog*exp(f(4,4,:,ilnrho))/(md(k)*unit_md)
              enddo
            enddo
          enddo
          if (lroot) print*, 'init_nd: Dust density set by dust-to-gas '// &
              'ratio  epsd =', eps_dtog
        case('gaussian_epsd')
          do n=n1,n2; do k=1,ndustspec
            if (ldensity_nolog) then
              f(:,:,n,ind(k)) = f(:,:,n,ind(k)) + f(:,:,n,ilnrho)* &
                  eps_dtog*sqrt( (1/Hepsd)**2 + 1 )*exp(-z(n)**2/(2*Hepsd**2))
            else
              f(:,:,n,ind(k)) = f(:,:,n,ind(k)) + exp(f(:,:,n,ilnrho))* &
                  eps_dtog*sqrt( (1/Hepsd)**2 + 1 )*exp(-z(n)**2/(2*Hepsd**2))
            endif
          enddo; enddo
          if (lroot) print*, 'init_nd: Gaussian epsd with epsd =', eps_dtog
        case('cosine_lnnd')
          do n=n1,n2; do k=1,ndustspec
            f(:,:,n,ind(k)) = f(:,:,n,ind(k)) + exp(nd_const*cos(kz_nd*z(n)))
          enddo; enddo
          if (lroot) print*, 'init_nd: Cosine lnnd with nd_const=', nd_const
        case('cosine_nd')
          do n=n1,n2; do k=1,ndustspec
            f(:,:,n,ind(k)) = f(:,:,n,ind(k)) + 1.0 + nd_const*cos(kz_nd*z(n))
          enddo; enddo
          if (lroot) print*, 'init_nd: Cosine nd with nd_const=', nd_const
        case('minimum_nd')
          where (f(:,:,:,ind).lt.nd_const) f(:,:,:,ind)=nd_const
          if (lroot) print*, 'init_nd: Minimum dust density nd_const=', nd_const
        case('kernel_cst')
          f(:,:,:,ind) = 0.
          f(:,:,:,ind(1)) = nd0
          if (lroot) print*, &
              'init_nd: Test of dust coagulation with constant kernel'
        case('kernel_lin')
          do k=1,ndustspec
            f(:,:,:,ind(k)) = &
                nd0*( exp(-mdminus(k)/mdave0)-exp(-mdplus(k)/mdave0) )
          enddo
          if (lroot) print*, &
              'init_nd: Test of dust coagulation with linear kernel'
        case default
!
!  Catch unknown values
!
          if (lroot) print*, 'init_nd: No such value for initnd: ', &
              trim(initnd(j))
          call stop_it('')

        endselect
!
!  End loop over initial conditions
!
      enddo
!
!  Initialize grain masses
!      
      if (lmdvar) then
        do k=1,ndustspec; f(:,:,:,imd(k)) = md(k); enddo
      endif
!
!  Initialize ice density
!      
      if (lmice) f(:,:,:,imi) = 0.
!
!  Take logarithm if necessary (remember that nd then really means ln nd)
!
      if (ldustdensity_log) f(l1:l2,m1:m2,n1:n2,ind(:)) = &
          log(f(l1:l2,m1:m2,n1:n2,ind(:)))
!
!  sanity check
!
      if ( notanumber(f(l1:l2,m1:m2,n1:n2,ind(:))) ) &
          call stop_it('init_nd: Imaginary dust number density values')
      if (lmdvar .and. notanumber(f(l1:l2,m1:m2,n1:n2,imd(:))) ) &
          call stop_it('init_nd: Imaginary dust density values')
      if (lmice .and. notanumber(f(l1:l2,m1:m2,n1:n2,imi(:))) ) &
          call stop_it('init_nd: Imaginary ice density values')
!
    endsubroutine init_nd
!***********************************************************************
    subroutine pencil_criteria_dustdensity()
! 
!  All pencils that the Dustdensity module depends on are specified here.
! 
!  20-11-04/anders: coded
!
      lpenc_requested(i_nd)=.true.
      if (ldustcoagulation) lpenc_requested(i_md)=.true.
      if (ldustcondensation) then
        lpenc_requested(i_mi)=.true.
        lpenc_requested(i_rho)=.true.
        lpenc_requested(i_rho1)=.true.
      endif
      if (ldustcontinuity) then
        lpenc_requested(i_divud)=.true.
        if (ldustdensity_log) then
          lpenc_requested(i_udglnnd)=.true.
        else
          lpenc_requested(i_udgnd)=.true.
        endif
      endif
      if (lmdvar) then
        lpenc_requested(i_md)=.true.
        if (ldustcontinuity) then
          lpenc_requested(i_gmd)=.true.
          lpenc_requested(i_udgmd)=.true.
        endif
      endif
      if (lmice) then
        lpenc_requested(i_mi)=.true.
        if (ldustcontinuity) then
          lpenc_requested(i_gmi)=.true.
          lpenc_requested(i_udgmi)=.true.
        endif
      endif
      if (ldustcoagulation) then
        lpenc_requested(i_TT1)=.true.
      endif
      if (ldustcondensation) then
        lpenc_requested(i_cc)=.true.
        lpenc_requested(i_cc1)=.true.
        lpenc_requested(i_rho1)=.true.
        lpenc_requested(i_TT1)=.true.
      endif
      if (ldiffd_dusttogasratio) lpenc_requested(i_del2lnrho)=.true.
      if (ldiffd_simplified .and. ldustdensity_log) &
          lpenc_requested(i_glnnd2)=.true.
      if ((ldiffd_simplified .or. ldiffd_dusttogasratio) .and. &
           .not. ldustdensity_log) lpenc_requested(i_del2nd)=.true.
      if ((ldiffd_simplified .or. ldiffd_dusttogasratio) .and. &
           ldustdensity_log) lpenc_requested(i_del2lnnd)=.true.
      if (ldiffd_hyper3) lpenc_requested(i_del6nd)=.true.
      if (ldiffd_dusttogasratio .and. .not. ldustdensity_log) &
          lpenc_requested(i_gndglnrho)=.true.
      if (ldiffd_dusttogasratio .and. ldustdensity_log) &
          lpenc_requested(i_glnndglnrho)=.true.
      if (ldiffd_hyper3lnnd) lpenc_requested(i_del6lnnd)=.true.
      if (lmdvar .and. diffmd/=0.) lpenc_requested(i_del2md)=.true.
      if (lmice .and. diffmi/=0.) lpenc_requested(i_del2mi)=.true.
!
      lpenc_diagnos(i_nd)=.true.
      if (maxval(idiag_epsdrms)/=0) lpenc_requested(i_rho1)=.true.
!
    endsubroutine pencil_criteria_dustdensity
!***********************************************************************
    subroutine pencil_interdep_dustdensity(lpencil_in)
!
!  Interdependency among pencils provided by the Dustdensity module
!  is specified here.
!         
!  20-11-04/anders: coded
!
      logical, dimension(npencils) :: lpencil_in
!
      if (lpencil_in(i_udgnd)) then
        lpencil_in(i_uud)=.true.
        lpencil_in(i_gnd)=.true.
      endif
      if (lpencil_in(i_udglnnd)) then
        lpencil_in(i_uud)=.true.
        lpencil_in(i_glnnd)=.true.
      endif
      if (lpencil_in(i_udgmd)) then
        lpencil_in(i_uud)=.true.
        lpencil_in(i_gmd)=.true.
      endif
      if (lpencil_in(i_udgmi)) then
        lpencil_in(i_uud)=.true.
        lpencil_in(i_gmi)=.true.
      endif
      if (lpencil_in(i_rhod)) then
        lpencil_in(i_nd)=.true.
        lpencil_in(i_md)=.true.
      endif
      if (lpencil_in(i_gndglnrho)) then
        lpencil_in(i_gnd)=.true.
        lpencil_in(i_glnrho)=.true.
      endif
      if (lpencil_in(i_glnndglnrho)) then
        lpencil_in(i_glnnd)=.true.
        lpencil_in(i_glnrho)=.true.
      endif
      if (lpencil_in(i_glnnd2)) lpencil_in(i_glnnd)=.true.
      if (lpencil_in(i_sdglnnd)) then
        lpencil_in(i_sdij)=.true.
        lpencil_in(i_glnnd)=.true.
      endif
!
    endsubroutine pencil_interdep_dustdensity
!***********************************************************************
    subroutine calc_pencils_dustdensity(f,p)
!
!  Calculate Dustdensity pencils.
!  Most basic pencils should come first, as others may depend on them.
!
!  13-nov-04/anders: coded
!
      use Global, only: set_global,global_derivs
      use Sub
!
      real, dimension (mx,my,mz,mvar+maux) :: f
      type (pencil_case) :: p
!      
      real, dimension (nx,3) :: tmp_pencil_3
      integer :: i,k,mm,nn
!      
      intent(inout) :: f,p
! nd
      do k=1,ndustspec
        if (lpencil(i_nd)) then
          if (ldustdensity_log) then
            p%nd(:,k)=exp(f(l1:l2,m,n,ind(k)))
          else
            p%nd(:,k)=f(l1:l2,m,n,ind(k))
          endif
        endif
! gnd
        if (lpencil(i_gnd)) then
          if (ldustdensity_log) then
            call grad(f,ind(k),tmp_pencil_3)
            do i=1,3
              p%gnd(:,i,k)=p%nd(:,k)*tmp_pencil_3(:,i)
            enddo
          else
            call grad(f,ind(k),p%gnd(:,:,k))
          endif
        endif
! glnnd
        if (lpencil(i_glnnd)) then
          if (ldustdensity_log) then
            call grad(f,ind(k),p%glnnd(:,:,k))
          else
            call grad(f,ind(k),tmp_pencil_3)
            do i=1,3
              p%glnnd(:,i,k)=tmp_pencil_3(:,i)/p%nd(:,k)
            enddo
          endif
        endif
! glnnd2
        if (lpencil(i_glnnd2)) call dot2_mn(p%glnnd(:,:,k),p%glnnd2(:,k))
! udgnd
        if (lpencil(i_udgnd)) then
          if (lupw_ndmdmi) then
            call u_dot_gradf(f,ind(k),p%gnd(:,:,k),p%uud(:,:,k),p%udgnd, &
                upwind=.true.)
          else
            call dot_mn(p%uud(:,:,k),p%gnd(:,:,k),p%udgnd)
          endif
        endif
! udglnnd
        if (lpencil(i_udglnnd)) then
          if (lupw_ndmdmi) then
            call u_dot_gradf(f,ind(k),p%uud(:,:,k),p%glnnd(:,:,k),p%udglnnd, &
                upwind=.true.)
          else
            call dot_mn(p%uud(:,:,k),p%glnnd,p%udglnnd)
          endif
        endif
! md
        if (lpencil(i_md)) then
          if (lmdvar)  then
            p%md(:,k)=f(l1:l2,m,n,imd(k))
          else
            p%md(:,k)=md(k)
          endif
        endif
! mi
        if (lpencil(i_mi)) then
          if (lmice) then
            p%mi(:,k)=f(l1:l2,m,n,imi(k))
          else
            p%mi(:,k)=0.
          endif
        endif
! gmd
        if (lpencil(i_gmd)) then
          if (lmdvar) then
            call grad(f,imd(k),p%gmd(:,:,k))
          else
            p%gmd(:,:,k)=0.
          endif
        endif
! gmi
        if (lpencil(i_gmi)) then
          if (lmice) then
            call grad(f,imi(k),p%gmi(:,:,k))
          else
            p%gmi(:,:,k)=0.
          endif
        endif
! udgmd
        if (lpencil(i_udgmd)) then
          if (lupw_ndmdmi) then
            call u_dot_gradf(f,ind(k),p%gmd(:,:,k),p%uud(:,:,k),p%udgmd, &
                upwind=.true.)
          else
            call dot_mn(p%uud(:,:,k),p%gmd(:,:,k),p%udgmd)
          endif
        endif
! udgmi
        if (lpencil(i_udgmi)) then
          if (lupw_ndmdmi) then
            call u_dot_gradf(f,ind(k),p%gmi(:,:,k),p%uud(:,:,k),p%udgmi, &
                upwind=.true.)
          else
            call dot_mn(p%uud(:,:,k),p%gmi(:,:,k),p%udgmi)
          endif
        endif
! rhod
        if (lpencil(i_rhod)) p%rhod(:,k)=p%nd(:,k)*p%md(:,k)
! sdglnnd
        if (lpencil(i_sdglnnd)) &
            call multmv_mn(p%sdij(:,:,:,k),p%glnnd(:,:,k),p%sdglnnd(:,:,k))
! del2nd
        if (lpencil(i_del2nd)) then
          if (ldustdensity_log) then
            if (headtt) then
              call warning('calc_pencils_dustdensity', &
                'del2nd not available for logarithmic dust density')
            endif
          else  
            call del2(f,ind(k),p%del2nd(:,k))
          endif
        endif
! del2lnnd
        if (lpencil(i_del2lnnd)) then
          if (ldustdensity_log) then
            call del2(f,ind(k),p%del2lnnd(:,k))
          else  
            if (headtt) then
              call warning('calc_pencils_dustdensity', &
                'del2lnnd not available for non-logarithmic dust density')
            endif
          endif
        endif
! del6nd
        if (lpencil(i_del6nd)) then
          if (ldustdensity_log) then
            if (lfirstpoint .and. lglobal_nolog_density) then
              do mm=1,my; do nn=1,mz
                call set_global(exp(f(:,mm,nn,ind(k))),mm,nn,'nd',mx)
              enddo; enddo
            endif
            if (lglobal_nolog_density) call global_derivs(m,n,'nd',der6=p%del6nd(:,k))
          else
            call del6(f,ind(k),p%del6nd(:,k))
          endif
        endif
! del6lnnd
        if (lpencil(i_del6lnnd)) then
          if (ldustdensity_log) then
            call del6(f,ind(k),p%del6lnnd(:,k))
          else
            if (headtt) then
              call warning('calc_pencils_dustdensity', &
                  'del6lnnd not available for non-logarithmic dust density')
            endif
          endif
        endif
! del2md
        if (lpencil(i_del2md)) then
          if (lmdvar) then
            call del2(f,imd(k),p%del2md(:,k))
          else
            p%del2md(:,k)=0.
          endif
        endif
! del2mi
        if (lpencil(i_del2mi)) then
          if (lmice) then
            call del2(f,imi(k),p%del2mi(:,k))
          else
            p%del2mi(:,k)=0.
          endif
        endif
! gndglnrho
        if (lpencil(i_gndglnrho)) &
            call dot_mn(p%gnd(:,:,k),p%glnrho(:,:),p%gndglnrho(:,k))
! glnndglnrho
        if (lpencil(i_glnndglnrho)) &
            call dot_mn(p%glnnd(:,:,k),p%glnrho(:,:),p%glnndglnrho(:,k))
      enddo       
!
    endsubroutine calc_pencils_dustdensity
!***********************************************************************
    subroutine dndmd_dt(f,df,p)
!
!  continuity equation
!  calculate dnd/dt = - u.gradnd - nd*divud
!
!   7-jun-02/axel: incoporated from subroutine pde
!
      use Sub
      use Mpicomm, only: stop_it
      use Slices, only: md_xy,md_xy2,md_xz,md_yz
!
      real, dimension (mx,my,mz,mvar+maux) :: f
      real, dimension (mx,my,mz,mvar) :: df
      type (pencil_case) :: p
!
      real, dimension (nx) :: mfluxcond,fdiffd
      integer :: k
!
      intent(in)  :: f,p
      intent(out) :: df
!
!  identify module and boundary conditions
!
      if (headtt  .or. ldebug) print*,'dndmd_dt: SOLVE dnd_dt, dmd_dt, dmi_dt'
      if (headtt)              call identify_bcs('nd',ind(1))
      if (lmdvar .and. headtt) call identify_bcs('md',imd(1))
      if (lmice .and. headtt)  call identify_bcs('mi',imi(1))
!
!  Continuity equations for nd, md and mi.
!
      if (ldustcontinuity) then
        do k=1,ndustspec
          if (ldustdensity_log) then
            df(l1:l2,m,n,ind(k)) = df(l1:l2,m,n,ind(k)) - &
                p%udglnnd(:,k) - p%divud(:,k)
          else
            df(l1:l2,m,n,ind(k)) = df(l1:l2,m,n,ind(k)) - &
                p%udgnd(:,k) - p%nd(:,k)*p%divud(:,k)
          endif
          if (lmdvar) df(l1:l2,m,n,imd(k)) = df(l1:l2,m,n,imd(k)) - p%udgmd(:,k)
          if (lmice)  df(l1:l2,m,n,imi(k)) = df(l1:l2,m,n,imi(k)) - p%udgmi(:,k)
        enddo
      endif
!
!  Calculate kernel of coagulation equation
!
      if (lcalcdkern .and. ldustcoagulation) call coag_kernel(f,p%TT1)
!
!  Dust coagulation due to sticking
!
      if (ldustcoagulation) call dust_coagulation(f,df,p)
!
!  Dust growth due to condensation on grains
!
      if (ldustcondensation) call dust_condensation(f,df,p,mfluxcond)
!
!  Loop over dust layers
!
      do k=1,ndustspec
!
!  Add diffusion on dust
!
        fdiffd=0.0
        diffus_diffnd=0.0   ! Do not sum diffusion from all dust species
!
        if (ldiffd_simplified) then
          if (ldustdensity_log) then
            fdiffd = fdiffd + diffnd*(p%del2lnnd(:,k) + p%glnnd2(:,k))
          else
            fdiffd = fdiffd + diffnd*p%del2nd(:,k)
          endif
          if (lfirst.and.ldt) diffus_diffnd=diffus_diffnd+diffnd*dxyz_2
        endif
!
        if (ldiffd_dusttogasratio) then
          if (ldustdensity_log) then
            fdiffd = fdiffd + diffnd*(p%del2lnnd(:,k) + p%glnnd2(:,k) - &
                p%glnndglnrho(:,k) - p%del2lnrho)
          else
            fdiffd = fdiffd + diffnd*(p%del2nd(:,k) - p%gndglnrho(:,k) - &
                p%nd(:,k)*p%del2lnrho)
          endif
          if (lfirst.and.ldt) diffus_diffnd=diffus_diffnd+diffnd*dxyz_2
        endif
!
        if (ldiffd_hyper3) then
          if (ldustdensity_log) then
            fdiffd = fdiffd + 1/p%nd(:,k)*diffnd_hyper3*p%del6nd(:,k)
          else
            fdiffd = fdiffd + diffnd_hyper3*p%del6nd(:,k)
          endif
          if (lfirst.and.ldt) diffus_diffnd=diffus_diffnd+diffnd_hyper3*dxyz_6
        endif
!
        if (ldiffd_hyper3lnnd) then
          if (ldustdensity_log) then
            fdiffd = fdiffd + diffnd_hyper3*p%del6lnnd(:,k)
          endif
          if (lfirst.and.ldt) diffus_diffnd=diffus_diffnd+diffnd_hyper3*dxyz_6
        endif
!
        df(l1:l2,m,n,ind(k)) = df(l1:l2,m,n,ind(k)) + fdiffd
!
        if (lmdvar) df(l1:l2,m,n,imd(k)) = &
            df(l1:l2,m,n,imd(k)) + diffmd*p%del2md(:,k)
        if (lmice) df(l1:l2,m,n,imi(k)) = &
            df(l1:l2,m,n,imi(k)) + diffmi*p%del2mi(:,k)
!
!  Diagnostic output
!
        if (ldiagnos) then
          if (idiag_ndm(k)/=0) call sum_mn_name(p%nd(:,k),idiag_ndm(k))
          if (idiag_nd2m(k)/=0) call sum_mn_name(p%nd(:,k)**2,idiag_nd2m(k))
          if (idiag_ndmin(k)/=0) &
              call max_mn_name(-p%nd(:,k),idiag_ndmin(k),lneg=.true.)
          if (idiag_ndmax(k)/=0) call max_mn_name(p%nd(:,k),idiag_ndmax(k))
          if (idiag_rhodm(k)/=0) then
            if (lmdvar) then
              call sum_mn_name(p%nd(:,k)*f(l1:l2,m,n,imd(k)),idiag_rhodm(k))
            else
              call sum_mn_name(p%nd(:,k)*md(k),idiag_rhodm(k))
            endif 
          endif
          if (idiag_epsdrms(k)/=0) then
            if (lmdvar) then
              call sum_mn_name((p%nd(:,k)*f(l1:l2,m,n,imd(k))*p%rho1)**2, &
                  idiag_epsdrms(k),lsqrt=.true.)
            else
              call sum_mn_name((p%nd(:,k)*md(k)*p%rho1)**2, &
                  idiag_epsdrms(k),lsqrt=.true.)
            endif 
          endif
          if (idiag_ndmt/=0) then
            if (lfirstpoint .and. k/=1) then
              lfirstpoint = .false.
              call sum_mn_name(p%nd(:,k),idiag_ndmt)
              lfirstpoint = .true.
            else
              call sum_mn_name(p%nd(:,k),idiag_ndmt)
            endif
          endif
          if (idiag_rhodmt/=0) then
            if (lfirstpoint .and. k/=1) then
              lfirstpoint = .false.
              if (lmdvar) then
                call sum_mn_name(f(l1:l2,m,n,imd(k))*p%nd(:,k),idiag_rhodmt)
              else
                call sum_mn_name(md(k)*p%nd(:,k),idiag_rhodmt)
              endif
              lfirstpoint = .true.
            else
              if (lmdvar) then
                call sum_mn_name(f(l1:l2,m,n,imd(k))*p%nd(:,k),idiag_rhodmt)
              else
                call sum_mn_name(md(k)*p%nd(:,k),idiag_rhodmt)
              endif
            endif
          endif
          if (idiag_rhoimt/=0) then
            if (lfirstpoint .and. k/=1) then
              lfirstpoint = .false.
              call sum_mn_name(f(l1:l2,m,n,imi(k))*p%nd(:,k),idiag_rhoimt)
              lfirstpoint = .true.
            else
              call sum_mn_name(f(l1:l2,m,n,imi(k))*p%nd(:,k),idiag_rhoimt)
            endif
          endif
        endif
!
!  Write md slices for use in Slices 
!    (the variable md is not accesible to Slices)
!
        if (lvid .and. lfirst) then
          if (lmdvar) then
            md_yz(m-m1+1,n-n1+1,k) = f(ix,m,n,imd(k))
            if (m == iy)  md_xz(:,n-n1+1,k)  = f(l1:l2,iy,n,imd(k))
            if (n == iz)  md_xy(:,m-m1+1,k)  = f(l1:l2,m,iz,imd(k))
            if (n == iz2) md_xy2(:,m-m1+1,k) = f(l1:l2,m,iz2,imd(k))
          else
            md_yz(m-m1+1,n-n1+1,k) = md(k)
            md_xz(:,n-n1+1,k)  = md(k)
            md_xy(:,m-m1+1,k)  = md(k)
            md_xy2(:,m-m1+1,k) = md(k)
          endif
        endif
!
!  End loop over dust layers
!
      enddo
!
    endsubroutine dndmd_dt
!***********************************************************************
    subroutine redist_mdbins(f)
!
!  Redistribute dust number density and dust density in mass bins
!
      use Mpicomm, only: stop_it

      real, dimension (mx,my,mz,mvar+maux) :: f
      real, dimension (nx,ndustspec) :: nd
      real, dimension (ndustspec) :: ndnew,mdnew,minew
      integer :: j,k,i_targ,l
!
!  Loop over pencil
!
      do m=m1,m2; do n=n1,n2
        nd(:,:) = f(l1:l2,m,n,ind)
        do l=1,nx
          md(:) = f(3+l,m,n,imd(:))
          if (lmice) mi(:) = f(3+l,m,n,imi(:))
          mdnew = 0.5*(mdminus+mdplus)
          ndnew = 0.
          minew = 0.
!
!  Check for interval overflows on all species
!          
          do k=1,ndustspec
            i_targ = k
            if (md(k) >= mdplus(k)) then     ! Gone to higher mass bin
              do j=k+1,ndustspec+1 
                i_targ = j
                if (md(k) >= mdminus(j) .and. md(k) < mdplus(j)) exit
              enddo
            elseif (md(k) < mdminus(k)) then ! Gone to lower mass bin
              do j=k-1,0,-1
                i_targ = j
                if (md(k) >= mdminus(j) .and. md(k) < mdplus(j)) exit
              enddo
            endif
!
!  Top boundary overflows are ignored
!
            if (i_targ == ndustspec+1) i_targ = ndustspec
!
!  Put all overflowing grains into relevant interval
!
            if (i_targ >= 1 .and. nd(l,k)/=0.) then
              mdnew(i_targ) = (nd(l,k)*md(k) + &
                  ndnew(i_targ)*mdnew(i_targ))/(nd(l,k) + ndnew(i_targ))
              if (lmice) minew(i_targ) = (nd(l,k)*mi(k) + &
                  ndnew(i_targ)*minew(i_targ))/(nd(l,k) + ndnew(i_targ))
              ndnew(i_targ) = ndnew(i_targ) + nd(l,k)
            elseif (i_targ == 0) then        !  Underflow below lower boundary
              if (lpscalar_nolog) then
                f(3+l,m,n,ilncc) = f(3+l,m,n,ilncc) + &
                     nd(l,k)*md(k)*unit_md*exp(-f(3+l,m,n,ilnrho))
              elseif (lpscalar) then
                f(3+l,m,n,ilncc) = log(exp(f(3+l,m,n,ilncc)) + &
                     nd(l,k)*md(k)*unit_md*exp(-f(3+l,m,n,ilnrho)))
              endif
            endif
          enddo
          f(3+l,m,n,ind(:)) = ndnew(:)
          f(3+l,m,n,imd(:)) = mdnew(:)
          if (lmice) f(3+l,m,n,imi(:)) = minew(:)
        enddo
      enddo; enddo
!
    endsubroutine redist_mdbins
!***********************************************************************
    subroutine dust_condensation(f,df,p,mfluxcond)
!
!  Calculate condensation of dust on existing dust surfaces
!
      use Mpicomm, only: stop_it

      real, dimension (mx,my,mz,mvar+maux) :: f
      real, dimension (mx,my,mz,mvar) :: df
      type (pencil_case) :: p
      real, dimension (nx,ndustspec) :: nd
      real, dimension (nx) :: mfluxcond
      real :: dmdfac
      integer :: k,l
!
      if (.not. lmdvar) call stop_it &
          ('dust_condensation: Dust condensation only works with lmdvar')
!
!  Calculate mass flux of condensing monomers
!          
      call get_mfluxcond(f,mfluxcond,p%rho,p%TT1,p%cc)
!
!  Loop over pencil
!      
      do l=1,nx
        do k=1,ndustspec
          dmdfac = surfd(k)*mfluxcond(l)/unit_md
          if (p%mi(l,k) + dt_beta(itsub)*dmdfac < 0.) then
            dmdfac = -p%mi(l,k)/dt_beta(itsub)
          endif
          if (p%cc(l) < 1e-6 .and. dmdfac > 0.) dmdfac=0.
          df(3+l,m,n,imd(k)) = df(3+l,m,n,imd(k)) + dmdfac
          df(3+l,m,n,imi(k)) = df(3+l,m,n,imi(k)) + dmdfac
          if (lpscalar_nolog) then
            df(3+l,m,n,ilncc) = df(3+l,m,n,ilncc) - &
                p%rho1(l)*dmdfac*p%nd(l,k)*unit_md
          elseif (lpscalar) then
            df(3+l,m,n,ilncc) = df(3+l,m,n,ilncc) - &
                p%rho1(l)*dmdfac*p%nd(l,k)*unit_md*p%cc1(l)
          endif
        enddo
      enddo
!
    endsubroutine dust_condensation
!***********************************************************************
    subroutine get_mfluxcond(f,mfluxcond,rho,TT1,cc)
!
!  Calculate mass flux of condensing monomers
!
      use Cdata
      use Mpicomm, only: stop_it
      use EquationOfState, only: getmu,eoscalc,ilnrho_ss
      use Sub

      real, dimension (mx,my,mz,mvar+maux) :: f
      real, dimension (nx) :: mfluxcond,rho,TT1,cc,pp,ppmon,ppsat,vth
      real, dimension (nx) :: supsatratio1
      real, save :: mu
!
      select case(dust_chemistry)

      case ('ice')
        if (it == 1) call getmu(mu)
        call eoscalc(ilnrho_ss,f(l1:l2,m,n,ilnrho),f(l1:l2,m,n,iss),pp=pp)
        ppmon = pp*cc*mu/mumon
        ppsat = 6.035e12*exp(-5938*TT1)
        vth = (3*k_B/(TT1*mmon))**0.5
        supsatratio1 = ppsat/ppmon

        mfluxcond = vth*cc*rho*(1-supsatratio1)
        if (ldiagnos) then
          if (idiag_ssrm/=0)   call sum_mn_name(1/supsatratio1(:),idiag_ssrm)
          if (idiag_ssrmax/=0) call max_mn_name(1/supsatratio1(:),idiag_ssrmax)
        endif

      case default
        call stop_it("get_mfluxcond: No valid dust chemistry specified.")

      endselect
!
    endsubroutine get_mfluxcond
!***********************************************************************
    subroutine coag_kernel(f,TT1)
!
!  Calculate mass flux of condensing monomers
!
      use Hydro, only: ul0,tl0,teta,ueta,tl01,teta1
      use Sub
!      
      real, dimension (mx,my,mz,mvar+maux) :: f
      real, dimension (nx) :: TT1
      real :: deltaud,deltaud_drift,deltaud_therm,deltaud_turbu,deltaud_drift2
      real :: ust
      integer :: i,j,l
      do l=1,nx
        if (lmdvar) md(:) = f(3+l,m,n,imd(:))
        if (lmice)  mi(:) = f(3+l,m,n,imi(:))
        do i=1,ndustspec
          do j=i,ndustspec
!
!  Relative macroscopic speed
!            
            call dot2 (f(3+l,m,n,iudx(j):iudz(j)) - &
                f(3+l,m,n,iudx(i):iudz(i)),deltaud_drift2)
            deltaud_drift = sqrt(deltaud_drift2)
!
!  Relative thermal speed is only important for very light particles
!            
            if (ldeltaud_thermal) deltaud_therm = &
                sqrt( 8*k_B/(pi*TT1(l))*(md(i)+md(j))/(md(i)*md(j)*unit_md) )
!
!  Relative turbulent speed depends on stopping time regimes
!
            if (ldeltaud_turbulent) then
              if ( (tausd1(l,i) > tl01 .and. tausd1(l,j) > tl01) .and. &
                   (tausd1(l,i) < teta1 .and. tausd1(l,j) < teta1)) then
                deltaud_turbu = ul0*3/(tausd1(l,j)/tausd1(l,i)+1.)* &
                    (1/(tl0*tausd1(l,j)))**0.5
              elseif (tausd1(l,i) < tl01 .and. tausd1(1,j) > tl01 .or. &
                  tausd1(l,i) > tl01 .and. tausd1(l,j) < tl01) then
                deltaud_turbu = ul0
              elseif (tausd1(l,i) < tl01 .and. tausd1(l,j) < tl01) then
                deltaud_turbu = ul0*tl0*0.5*(tausd1(l,j) + tausd1(l,i))
              elseif (tausd1(l,i) > teta1 .and. tausd1(l,j) > teta1) then
                deltaud_turbu = ueta/teta*(tausd1(l,i)/tausd1(l,j)-1.)
              endif
            endif
!
!  Add all speed contributions quadratically
!            
            deltaud = sqrt(deltaud_drift**2+deltaud_therm**2+deltaud_turbu**2)
!
!  Stick only when relative speed is below sticking speed
!
            if (ludstickmax) then
              ust = ustcst * (ad(i)*ad(j)/(ad(i)+ad(j)))**(2/3.) * &
                  ((md(i)+md(j))/(md(i)*md(j)*unit_md))**(1/2.) 
              if (deltaud > ust) deltaud = 0.
            endif
            dkern(l,i,j) = scolld(i,j)*deltaud
            dkern(l,j,i) = dkern(l,i,j)
          enddo
        enddo
      enddo
!
    endsubroutine coag_kernel
!***********************************************************************
    subroutine dust_coagulation(f,df,p)
!
!  Dust coagulation due to sticking
!
      real, dimension (mx,my,mz,mvar+maux) :: f
      real, dimension (mx,my,mz,mvar) :: df 
      type (pencil_case) :: p
      real :: dndfac
      integer :: i,j,k,l
!
      do l=1,nx
        do i=1,ndustspec
          do j=i,ndustspec
            dndfac = -dkern(l,i,j)*p%nd(l,i)*p%nd(l,j)
            if (dndfac/=0.) then
              df(3+l,m,n,ind(i)) = df(3+l,m,n,ind(i)) + dndfac
              df(3+l,m,n,ind(j)) = df(3+l,m,n,ind(j)) + dndfac
              do k=j,ndustspec+1
                if (p%md(l,i) + p%md(l,j) >= mdminus(k) &
                    .and. p%md(l,i) + p%md(l,j) < mdplus(k)) then
                  if (lmdvar) then
                    df(3+l,m,n,ind(k)) = df(3+l,m,n,ind(k)) - dndfac
                    if (p%nd(l,k) == 0.) then
                      f(3+l,m,n,imd(k)) = p%md(l,i) + p%md(l,j)
                    else
                      df(3+l,m,n,imd(k)) = df(3+l,m,n,imd(k)) - &
                          (p%md(l,i) + p%md(l,j) - p%md(l,k))*1/p%nd(l,k)*dndfac
                    endif
                    if (lmice) then
                      if (p%nd(l,k) == 0.) then
                        f(3+l,m,n,imi(k)) = p%mi(l,i) + p%mi(l,j)
                      else
                        df(3+l,m,n,imi(k)) = df(3+l,m,n,imi(k)) - &
                            (p%mi(l,i) + p%mi(l,j) - p%mi(l,k))* &
                            1/p%nd(l,k)*dndfac
                      endif
                    endif
                    exit
                  else
                    df(3+l,m,n,ind(k)) = df(3+l,m,n,ind(k)) - &
                        dndfac*(p%md(l,i)+p%md(l,j))/p%md(l,k)
                    exit
                  endif
                endif
              enddo
            endif
          enddo
        enddo
      enddo
!
    endsubroutine dust_coagulation
!***********************************************************************
    subroutine read_dustdensity_init_pars(unit,iostat)
      integer, intent(in) :: unit
      integer, intent(inout), optional :: iostat
                                                                                                   
      if (present(iostat)) then
        read(unit,NML=dustdensity_init_pars,ERR=99, IOSTAT=iostat)
      else
        read(unit,NML=dustdensity_init_pars,ERR=99)
      endif
                                                                                                   
                                                                                                   
99    return
    endsubroutine read_dustdensity_init_pars
!***********************************************************************
    subroutine write_dustdensity_init_pars(unit)
      integer, intent(in) :: unit
                                                                                                   
      write(unit,NML=dustdensity_init_pars)
                                                                                                   
    endsubroutine write_dustdensity_init_pars
!***********************************************************************
    subroutine read_dustdensity_run_pars(unit,iostat)
      integer, intent(in) :: unit
      integer, intent(inout), optional :: iostat
                                                                                                   
      if (present(iostat)) then
        read(unit,NML=dustdensity_run_pars,ERR=99, IOSTAT=iostat)
      else
        read(unit,NML=dustdensity_run_pars,ERR=99)
      endif
                                                                                                   
                                                                                                   
99    return
    endsubroutine read_dustdensity_run_pars
!***********************************************************************
    subroutine write_dustdensity_run_pars(unit)
      integer, intent(in) :: unit
                                                                                                   
      write(unit,NML=dustdensity_run_pars)
                                                                                                   
    endsubroutine write_dustdensity_run_pars
!***********************************************************************
    subroutine null_dust_vars(f)
!
!  Force certain dust variables to be zero if they have become negative
!
      real, dimension (mx,my,mz,mvar+maux) :: f
      integer :: k,l
!
      do l=l1,l2; do m=m1,m2; do n=n1,n2
        do k=1,ndustspec
          if (f(l,m,n,ind(k)) < 0.) f(l,m,n,ind(k)) = 0.
          if (lmice .and. (f(l,m,n,imi(k)) < 0.)) f(l,m,n,imi(k)) = 0.
        enddo
        if (lpscalar_nolog .and. (f(l,m,n,ilncc) < 0.)) f(l,m,n,ilncc) = 1e-6
      enddo; enddo; enddo
!
    endsubroutine null_dust_vars
!***********************************************************************
    subroutine reinit_criteria_dust
!
!  Force reiniting of dust variables if certain criteria are fulfilled
!
      use Sub, only: notanumber
!      
      integer :: k
!
      if (.not. lreinit) then
        if (lreinit_dustvars_ndneg) then
          if (lroot .and. (.not. ldustdensity_log)) then 
            do k=1,ndustspec
              if (fname(idiag_ndmin(k)) < 0. .or. &
                  notanumber(fname(idiag_ndm(k)))) then
                print*, 'reinit_criteria_dust: ndmin < 0., so reinit uud, nd'
                lreinit=.true.
                nreinit=2
                reinit_vars(1)='uud'
                reinit_vars(2)='nd'
              endif
            enddo
          endif
        endif
      endif
!
    endsubroutine reinit_criteria_dust
!***********************************************************************
    subroutine rprint_dustdensity(lreset,lwrite)
!
!  reads and registers print parameters relevant for compressible part
!
!   3-may-02/axel: coded
!  27-may-02/axel: added possibility to reset list
!
      use Sub
      use General, only: chn
!
      integer :: iname,k
      logical :: lreset,lwr
      logical, optional :: lwrite
      character (len=4) :: sdust,sdustspec,snd1,smd1,smi1
!
!  Write information to index.pro that should not be repeated for all species
!
      lwr = .false.
      if (present(lwrite)) lwr=lwrite

      if (lwr) then
        write(3,*) 'ndustspec=',ndustspec
        write(3,*) 'nname=',nname
      endif
!
!  reset everything in case of reset
!
      if (lreset) then
        idiag_ndm=0; idiag_ndmin=0; idiag_ndmax=0; idiag_ndmt=0; idiag_rhodm=0
        idiag_nd2m=0; idiag_rhodmt=0; idiag_rhoimt=0; idiag_epsdrms=0
      endif

      call chn(ndustspec,sdustspec)
!
!  Define arrays for multiple dust species
!
      if (lwr .and. ndustspec/=1) then
        write(3,*) 'i_ndm=intarr('//trim(sdustspec)//')'
        write(3,*) 'i_ndmin=intarr('//trim(sdustspec)//')'
        write(3,*) 'i_ndmax=intarr('//trim(sdustspec)//')'
        write(3,*) 'i_rhodm=intarr('//trim(sdustspec)//')'
        write(3,*) 'i_epsdrms=intarr('//trim(sdustspec)//')'
      endif
!
!  Loop over dust species (for species-dependent diagnostics)
!
      do k=1,ndustspec
        call chn(k-1,sdust)
        if (ndustspec == 1) sdust=''
!
!  iname runs through all possible names that may be listed in print.in
!
        if(lroot.and.ip<14) print*,'rprint_dustdensity: run through parse list'
        do iname=1,nname
          call parse_name(iname,cname(iname),cform(iname), &
              'ndm'//trim(sdust),idiag_ndm(k))
          call parse_name(iname,cname(iname),cform(iname), &
              'nd2m'//trim(sdust),idiag_nd2m(k))
          call parse_name(iname,cname(iname),cform(iname), &
              'ndmin'//trim(sdust),idiag_ndmin(k))
          call parse_name(iname,cname(iname),cform(iname), &
              'ndmax'//trim(sdust),idiag_ndmax(k))
          call parse_name(iname,cname(iname),cform(iname), &
              'rhodm'//trim(sdust),idiag_rhodm(k))
          call parse_name(iname,cname(iname),cform(iname), &
              'epsdrms'//trim(sdust),idiag_epsdrms(k))
        enddo
!
!  write column where which variable is stored
!
        if (lwr) then
          call chn(k-1,sdust)
          sdust = '['//sdust//']'
          if (ndustspec == 1) sdust=''
          if (idiag_ndm(k)/=0) &
              write(3,*) 'i_ndm'//trim(sdust)//'=',idiag_ndm(k)
          if (idiag_nd2m(k)/=0) &
              write(3,*) 'i_nd2m'//trim(sdust)//'=',idiag_nd2m(k)
          if (idiag_ndmin(k)/=0) &
              write(3,*) 'i_ndmin'//trim(sdust)//'=',idiag_ndmin(k)
          if (idiag_ndmax(k)/=0) &
              write(3,*) 'i_ndmax'//trim(sdust)//'=',idiag_ndmax(k)
          if (idiag_rhodm(k)/=0) &
              write(3,*) 'i_rhodm'//trim(sdust)//'=',idiag_rhodm(k)
          if (idiag_epsdrms(k)/=0) &
              write(3,*) 'i_epsdrms'//trim(sdust)//'=',idiag_epsdrms(k)
        endif
!
!  End loop over dust layers
!
      enddo
!
!  Non-species-dependent diagnostics
!
      do iname=1,nname
        call parse_name(iname,cname(iname),cform(iname),'ndmt',idiag_ndmt)
        call parse_name(iname,cname(iname),cform(iname),'rhodmt',idiag_rhodmt)
        call parse_name(iname,cname(iname),cform(iname),'rhoimt',idiag_rhoimt)
        call parse_name(iname,cname(iname),cform(iname),'ssrm',idiag_ssrm)
        call parse_name(iname,cname(iname),cform(iname),'ssrmax',idiag_ssrmax)
      enddo
      if (lwr) then
        if (idiag_ndmt/=0)   write(3,*) 'i_ndmt=',idiag_ndmt
        if (idiag_rhodmt/=0) write(3,*) 'i_rhodmt=',idiag_rhodmt
        if (idiag_rhoimt/=0) write(3,*) 'i_rhoimt=',idiag_rhoimt
        if (idiag_ssrm/=0)   write(3,*) 'i_ssrm=',idiag_ssrm
        if (idiag_ssrmax/=0) write(3,*) 'i_ssrmax=',idiag_ssrmax
      endif
!
!  Write dust index in short notation
!      
      call chn(ind(1),snd1)
      if (lmdvar) call chn(imd(1),smd1)
      if (lmice)  call chn(imi(1),smi1)
      if (lwr) then
        if (lmdvar .and. lmice) then
          write(3,*) 'ind=indgen('//trim(sdustspec)//') + '//trim(snd1)
          write(3,*) 'imd=indgen('//trim(sdustspec)//') + '//trim(smd1)
          write(3,*) 'imi=indgen('//trim(sdustspec)//') + '//trim(smi1)
        elseif (lmdvar) then
          write(3,*) 'ind=indgen('//trim(sdustspec)//') + '//trim(snd1)
          write(3,*) 'imd=indgen('//trim(sdustspec)//') + '//trim(smd1)
          write(3,*) 'imi=0'
        else
          write(3,*) 'ind=indgen('//trim(sdustspec)//') + '//trim(snd1)
          write(3,*) 'imd=0'
          write(3,*) 'imi=0'
        endif
      endif
!
    endsubroutine rprint_dustdensity
!***********************************************************************

endmodule Dustdensity
