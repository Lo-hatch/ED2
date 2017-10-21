!==========================================================================================!
!==========================================================================================!
! MODULE: VEGETATION_DYNAMICS
!
!> \brief   Handles vegetation growth, phenology, reproduction, and disturbance.
!> \details This subroutine first handles any prescribed events, then moves on to phenology,
!>          biomass growth, structural growth, reproduction, then disturbance.
!> \author  Translated from ED1 by David Medvigy, Ryan Knox and Marcos Longo
!> \author  18 Oct 2017. Turned into a module for safer interfaces (Marcos Longo)
!------------------------------------------------------------------------------------------!
module vegetation_dynamics
   contains

   !=======================================================================================!
   !=======================================================================================!
   !    Main driver for calling long-term vegetation dynamics.                             !
   !---------------------------------------------------------------------------------------!
   subroutine veg_dynamics_driver(new_month,new_year)
      use grid_coms            , only : ngrids
      use ed_misc_coms         , only : current_time                  & ! intent(in)
                                      , dtlsm                         & ! intent(in)
                                      , frqsum                        & ! intent(in)
                                      , ibigleaf                      ! ! intent(in)
      use disturbance_utils    , only : apply_disturbances            & ! subroutine
                                      , site_disturbance_rates        ! ! subroutine
      use fuse_fiss_utils      , only : old_fuse_patches              & ! subroutine
                                      , new_fuse_patches              & ! subroutine
                                      , terminate_patches             & ! subroutine
                                      , rescale_patches               ! ! subroutine
      use ed_state_vars        , only : edgrid_g                      & ! intent(inout)
                                      , edtype                        & ! variable type
                                      , polygontype                   ! ! variable type
      use growth_balive        , only : dbalive_dt                    ! ! subroutine
      use consts_coms          , only : day_sec                       & ! intent(in)
                                      , yr_day                        ! ! intent(in)
      use mem_polygons         , only : maxpatch                      ! ! intent(in)
      use average_utils        , only : normalize_ed_today_vars       & ! sub-routine
                                      , normalize_ed_todaynpp_vars    & ! sub-routine
                                      , zero_ed_today_vars            ! ! sub-routine
      use canopy_radiation_coms, only : ihrzrad                       ! ! intent(in)
      use hrzshade_utils       , only : split_hrzshade                & ! sub-routine
                                      , reset_hrzshade                ! ! sub-routine
      use structural_growth    , only : dbdead_dt                     ! ! sub-routine
      use ed_cn_utils          , only : print_C_and_N_budgets         ! ! sub-routine
      use reproduction         , only : reproduction_driver           ! ! sub-routine
      use soil_respiration     , only : update_C_and_N_pools          ! ! sub-routine
      use phenology_driv       , only : phenology_driver              ! ! sub-routine
      use update_derived_utils , only : update_workload               & ! sub-routine
                                      , update_polygon_derived_props  ! ! sub-routine
      use fusion_fission_coms  , only : ifusion                       ! ! intent(in)
      implicit none
      !----- Arguments. -------------------------------------------------------------------!
      logical          , intent(in)   :: new_month    !< First dtlsm of a new month?
      logical          , intent(in)   :: new_year     !< First dtlsm of a new year?
      !----- Local variables. -------------------------------------------------------------!
      type(edtype)     , pointer      :: cgrid
      type(polygontype), pointer      :: cpoly
      real                            :: dtlsm_o_day
      real                            :: one_o_year
      integer                         :: doy
      integer                         :: ifm
      !----- External functions. ----------------------------------------------------------!
      integer          , external     :: julday
      !------------------------------------------------------------------------------------!
      integer                       :: ipy
      integer                       :: isi

      !----- Find the day of year. --------------------------------------------------------!
      doy = julday(current_time%month, current_time%date, current_time%year)
     
      !----- Time factor for normalizing daily variables updated on the DTLSM step. -------!
      dtlsm_o_day = dtlsm / day_sec
      !----- Time factor for averaging dailies. -------------------------------------------!
      one_o_year  = 1.0 / yr_day

      !----- Apply events. ----------------------------------------------------------------!
      call prescribed_event(current_time%year,doy)

     
      !------------------------------------------------------------------------------------!
      !   Loop over all domains.                                                           !
      !------------------------------------------------------------------------------------!
      do ifm=1,ngrids

         cgrid => edgrid_g(ifm) 

         !---------------------------------------------------------------------------------!
         !     The following block corresponds to the daily time-step.                     !
         !---------------------------------------------------------------------------------!
         !----- Standardise the fast-scale uptake and respiration, for growth rates. ------!
         call normalize_ed_today_vars(cgrid)
         !----- Update phenology and growth of live tissues. ------------------------------!
         call phenology_driver(cgrid,doy,current_time%month, dtlsm_o_day)
         call dbalive_dt(cgrid,one_o_year)
         !---------------------------------------------------------------------------------!


         !---------------------------------------------------------------------------------!
         !     The following block corresponds to the monthly time-step:                   !
         !---------------------------------------------------------------------------------!
         if (new_month) then

            !----- Update the mean workload counter. --------------------------------------!
            call update_workload(cgrid)

            !----- Update the growth of the structural biomass. ---------------------------!
            call dbdead_dt(cgrid, current_time%month)

            !----- Solve the reproduction rates. ------------------------------------------!
            call reproduction_driver(cgrid,current_time%month)

            !----- Update the fire disturbance rates. -------------------------------------!
            call fire_frequency(cgrid)

            !----- This is actually the yearly time-step, apply the disturbances. ---------!
            if (new_year) then
               !----- Update the disturbance rates. ---------------------------------------!
               call site_disturbance_rates(current_time%year, cgrid)
               call apply_disturbances(cgrid)
               !---------------------------------------------------------------------------!
            end if
            !------------------------------------------------------------------------------!
         end if
         !---------------------------------------------------------------------------------!

         !------  update dmean and mmean values for NPP allocation terms ------------------!
         call normalize_ed_todayNPP_vars(cgrid)
         
         !---------------------------------------------------------------------------------!
         !     This should be done every day, but after the longer-scale steps.  We update !
         ! the carbon and nitrogen pools, and re-set the daily variables.                  !
         !---------------------------------------------------------------------------------!
         call update_C_and_N_pools(cgrid)
         call zero_ed_today_vars(cgrid)
         !---------------------------------------------------------------------------------!


         !---------------------------------------------------------------------------------!
         !      Patch dynamics.                                                            !
         !---------------------------------------------------------------------------------!
         if (new_year) then
            select case(ibigleaf)
            case (0)
               !---------------------------------------------------------------------------!
               !    Size and age structure.  Fuse patches last, after all updates have     !
               ! been applied.  This reduces the number of patch variables that actually   !
               ! need to be fused.  After fusing, we also check whether there are patches  !
               ! that are too small, and terminate them.                                   !
               !---------------------------------------------------------------------------!
               if (maxpatch >= 0) then
                  select case (ifusion)
                  case (0)
                     call old_fuse_patches(cgrid,ifm,.false.)
                  case (1)
                     call new_fuse_patches(cgrid,ifm,.false.)
                  end select
               end if
               do ipy = 1,cgrid%npolygons
                  cpoly => cgrid%polygon(ipy)
                    
                  do isi = 1, cpoly%nsites
                     call terminate_patches(cpoly%site(isi))
                  end do
               end do
               !---------------------------------------------------------------------------!


               !---------------------------------------------------------------------------!
               !     Call routine that will split patches based on probability of being    !
               ! shaded by taller neighbours.                                              !
               !---------------------------------------------------------------------------!
               select case (ihrzrad)
               case (0,4)
                  !----- Make sure no horizontal shading is applied. ----------------------!
                  do ipy = 1,cgrid%npolygons
                     cpoly => cgrid%polygon(ipy)
                     do isi = 1, cpoly%nsites
                        call reset_hrzshade(cpoly%site(isi))
                     end do
                  end do
                  !------------------------------------------------------------------------!
               case default
                  !----- Run patch light assignment. --------------------------------------!
                  do ipy = 1,cgrid%npolygons
                     cpoly => cgrid%polygon(ipy)
                     do isi = 1, cpoly%nsites
                        call split_hrzshade(cpoly%site(isi),isi)
                     end do
                  end do
                  !------------------------------------------------------------------------!
               end select
               !---------------------------------------------------------------------------!

            case (1)
               !---------------------------------------------------------------------------!
               !    Big leaf.  All that we do is rescale the patches.                      !
               !---------------------------------------------------------------------------!
               do ipy = 1,cgrid%npolygons
                  cpoly => cgrid%polygon(ipy)
                    
                  do isi = 1, cpoly%nsites
                     call rescale_patches(cpoly%site(isi))
                  end do
               end do
               !---------------------------------------------------------------------------!
            end select
            !------------------------------------------------------------------------------!
         end if
         !---------------------------------------------------------------------------------!



         !---------------------------------------------------------------------------------!
         !     Update polygon-level properties that are derived from patches and cohorts.  !
         !---------------------------------------------------------------------------------!
         call update_polygon_derived_props(edgrid_g(ifm))
         !---------------------------------------------------------------------------------!



         !----- Print the carbon and nitrogen budget. -------------------------------------!
         call print_C_and_N_budgets(cgrid)
         !---------------------------------------------------------------------------------!

      end do

      return
   end subroutine veg_dynamics_driver
   !=======================================================================================!
   !=======================================================================================!






   !=======================================================================================!
   !=======================================================================================!
   !     This subroutine is the a dummy version of the main driver for the longer-term     !
   ! vegetation dynamics.  Even though all "tendency" terms will be normally computed,     !
   ! none of them will be applied to the vegetation, so the plant community will remain    !
   ! the same throughout the entire simulation.                                            !
   !---------------------------------------------------------------------------------------!
   subroutine veg_dynamics_driver_eq_0(new_month,new_year)
      use grid_coms           , only : ngrids
      use ed_misc_coms        , only : current_time                 & ! intent(in)
                                     , dtlsm                        ! ! intent(in)
      use disturbance_utils   , only : apply_disturbances           & ! subroutine
                                     , site_disturbance_rates       ! ! subroutine
      use ed_state_vars       , only : edgrid_g                     & ! intent(inout)
                                     , edtype                       ! ! variable type
      use growth_balive       , only : dbalive_dt                   & ! subroutine
                                     , dbalive_dt_eq_0              ! ! subroutine
      use consts_coms         , only : day_sec                      & ! intent(in)
                                     , yr_day                       ! ! intent(in)
      use average_utils       , only : normalize_ed_today_vars      & ! sub-routine
                                     , normalize_ed_todaynpp_vars   & ! sub-routine
                                     , zero_ed_today_vars           ! ! sub-routine
      use structural_growth   , only : dbdead_dt_eq_0               ! ! sub-routine
      use ed_cn_utils         , only : print_C_and_N_budgets        ! ! sub-routine
      use reproduction        , only : reproduction_driver_eq_0     ! ! sub-routine
      use phenology_driv      , only : phenology_driver_eq_0        ! ! sub-routine
      use update_derived_utils, only : update_workload              & ! sub-routine
                                     , update_polygon_derived_props ! ! sub-routine
      implicit none
      !----- Arguments. -------------------------------------------------------------------!
      logical     , intent(in)   :: new_month
      logical     , intent(in)   :: new_year
      !----- Local variables. -------------------------------------------------------------!
      type(edtype), pointer      :: cgrid
      real                       :: dtlsm_o_day
      real                       :: one_o_year
      integer                    :: doy
      integer                    :: ifm
      !----- External functions. ----------------------------------------------------------!
      integer     , external     :: julday
      !------------------------------------------------------------------------------------!

      !----- Find the day of year. --------------------------------------------------------!
      doy = julday(current_time%month, current_time%date, current_time%year)
     
      !----- Time factor for normalizing daily variables updated on the DTLSM step. -------!
      dtlsm_o_day = dtlsm / day_sec
      !----- Time factor for averaging dailies. -------------------------------------------!
      one_o_year  = 1.0 / yr_day


      !------------------------------------------------------------------------------------!
      !   Loop over all domains.                                                           !
      !------------------------------------------------------------------------------------!
      do ifm=1,ngrids

         cgrid => edgrid_g(ifm) 

         !---------------------------------------------------------------------------------!
         !     The following block corresponds to the daily time-step.                     !
         !---------------------------------------------------------------------------------!
         !----- Standardise the fast-scale uptake and respiration, for growth rates. ------!
         call normalize_ed_today_vars(cgrid)
         !----- Update phenology and growth of live tissues. ------------------------------!
         call phenology_driver_eq_0(cgrid,doy,current_time%month, dtlsm_o_day)
         call dbalive_dt_eq_0(cgrid,one_o_year)
         !---------------------------------------------------------------------------------!



         !---------------------------------------------------------------------------------!
         !     The following block corresponds to the monthly time-step:                   !
         !---------------------------------------------------------------------------------!
         if (new_month) then

            !----- Update the mean workload counter. --------------------------------------!
            call update_workload(cgrid)

            !----- Update the growth of the structural biomass. ---------------------------!
            call dbdead_dt_eq_0(cgrid, current_time%month)

            !----- Solve the reproduction rates. ------------------------------------------!
            call reproduction_driver_eq_0(cgrid)

            !----- Update the fire disturbance rates. -------------------------------------!
            call fire_frequency(cgrid)

            !----- Update the disturbance rates. ------------------------------------------!
            if (new_year) then
               call site_disturbance_rates(current_time%year, cgrid)
               !----- We bypass the disturbance routine alltogether. ----------------------!
            end if
            !------------------------------------------------------------------------------!
         end if
         !---------------------------------------------------------------------------------!


         !------  update dmean and mmean values for NPP allocation terms ------------------!
         call normalize_ed_todayNPP_vars(cgrid)
         !---------------------------------------------------------------------------------!

         
         !---------------------------------------------------------------------------------!
         !     This should be done every day, but after the longer-scale steps.  We re-set !
         ! the daily variables that are not for output.                                    !
         !---------------------------------------------------------------------------------!
         call zero_ed_today_vars(cgrid)
         !---------------------------------------------------------------------------------!



         !---------------------------------------------------------------------------------!
         !     Update polygon-level properties that are derived from patches and cohorts.  !
         !---------------------------------------------------------------------------------!
         call update_polygon_derived_props(cgrid)
         !---------------------------------------------------------------------------------!



         !----- Print the carbon and nitrogen budget. -------------------------------------!
         call print_C_and_N_budgets(cgrid)
         !---------------------------------------------------------------------------------!
      end do

      return
   end subroutine veg_dynamics_driver_eq_0
   !=======================================================================================!
   !=======================================================================================!
end module vegetation_dynamics
!==========================================================================================!
!==========================================================================================!
