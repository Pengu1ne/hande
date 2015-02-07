module dmqmc

! Main loop for performing DMQMC calculations.

use fciqmc_data
use proc_pointers
implicit none

contains

    subroutine do_dmqmc(sys)

        ! Run DMQMC calculation. We run from a beta=0 to a value of beta
        ! specified by the user and then repeat this main loop beta_loops
        ! times, to accumulate statistics for each value for beta.

        ! In/Out:
        !    sys: system being studied.  NOTE: if modified inside a procedure,
        !         it should be returned in its original (ie unmodified state)
        !         at the end of the procedure.

        use parallel
        use annihilation, only: direct_annihilation
        use bit_utils, only: count_set_bits
        use bloom_handler, only: init_bloom_stats_t, bloom_mode_fixedn, &
                                 bloom_stats_t, accumulate_bloom_stats, write_bloom_report
        use determinants, only: det_info_t, alloc_det_info_t, dealloc_det_info_t
        use dmqmc_estimators
        use dmqmc_procedures
        use excitations, only: excit_t
        use qmc_common
        use interact, only: fciqmc_interact
        use restart_hdf5, only: restart_info_global, dump_restart_hdf5
        use system
        use calc, only: seed, initiator_approximation
        use dSFMT_interface, only: dSFMT_t
        use utils, only: rng_init_info

        type(sys_t), intent(inout) :: sys

        integer :: idet, ireport, icycle, iparticle, iteration, ireplica
        integer :: beta_cycle
        integer(int_64) :: init_tot_nparticles
        real(dp) :: tot_nparticles_old(sampling_size), real_population(sampling_size)
        integer(int_64) :: nattempts
        integer :: nel_temp, nattempts_current_det
        type(det_info_t) :: cdet1, cdet2
        integer(int_p) :: nspawned, ndeath
        type(excit_t) :: connection
        integer :: spawning_end, nspawn_events
        logical :: soft_exit
        real :: t1, t2
        type(dSFMT_t) :: rng
        type(bloom_stats_t) :: bloom_stats

        ! Allocate det_info_t components. We need two cdet objects for each 'end'
        ! which may be spawned from in the DMQMC algorithm.
        call alloc_det_info_t(sys, cdet1, .false.)
        call alloc_det_info_t(sys, cdet2, .false.)

        ! Initialise bloom_stats components to the following parameters.
        call init_bloom_stats_t(bloom_stats, mode=bloom_mode_fixedn, encoding_factor=real_factor)

        ! Main DMQMC loop.
        if (parent) then
            call rng_init_info(seed+iproc)
            call write_fciqmc_report_header()
        end if
        ! Initialise timer.
        call cpu_time(t1)

        ! When we accumulate data throughout a run, we are actually accumulating
        ! results from the psips distribution from the previous iteration.
        ! For example, in the first iteration, the trace calculated will be that
        ! of the initial distribution, which corresponds to beta=0. Hence, in the
        ! output we subtract one from the iteration number, and run for one more
        ! report loop, asimplemented in the line of code below.
        nreport = nreport+1
                            
        if (all_sym_sectors) nel_temp = sys%nel
        init_tot_nparticles = nint(D0_population, int_64)

        do beta_cycle = 1, beta_loops

            call init_dmqmc_beta_loop(rng, beta_cycle)

            ! Distribute psips uniformly along the diagonal of the density
            ! matrix.
            call create_initial_density_matrix(rng, sys, init_tot_nparticles, tot_nparticles)

            ! Allow the shift to vary from the very start of the beta loop, if
            ! this condition is met.
            vary_shift = tot_nparticles >= target_particles

            do ireport = 1, nreport

                call init_report_loop(bloom_stats)
                tot_nparticles_old = tot_nparticles

                do icycle = 1, ncycles

                    call init_mc_cycle(real_factor, nattempts, ndeath)

                    iteration = (ireport-1)*ncycles + icycle

                    do idet = 1, tot_walkers ! loop over walkers/dets

                        ! f points to the bitstring that is spawning, f2 to the
                        ! other bit string.
                        cdet1%f => walker_dets(:sys%basis%string_len,idet)
                        cdet1%f2 => walker_dets((sys%basis%string_len+1):(2*sys%basis%string_len),idet)
                        cdet2%f => walker_dets((sys%basis%string_len+1):(2*sys%basis%string_len),idet)
                        cdet2%f2 => walker_dets(:sys%basis%string_len,idet)

                        ! If using multiple symmetry sectors then find the
                        ! symmetry labels of this particular det.
                        if (all_sym_sectors) then
                            sys%nel = sum(count_set_bits(cdet1%f))
                            sys%nvirt = sys%lattice%nsites - sys%nel
                        end if

                        ! Decode and store the the relevant information for
                        ! both bitstrings. Both of these bitstrings are required
                        ! to refer to the correct element in the density matrix.
                        call decoder_ptr(sys, cdet1%f, cdet1)
                        call decoder_ptr(sys, cdet2%f, cdet2)

                        ! Extract the real signs from the encoded signs.
                        real_population = real(walker_population(:,idet),dp)/real_factor

                        ! Call wrapper function which calls routines to update
                        ! all estimators being calculated, and also always
                        ! updates the trace separately.
                        ! Note DMQMC averages over multiple loops over
                        ! temperature/imaginary time so only get data from one
                        ! temperature value per ncycles.
                        if (icycle == 1) call update_dmqmc_estimators(sys, idet, iteration)

                        do ireplica = 1, sampling_size

                            ! If this condition is met then there will only be
                            ! one det in this symmetry sector, so don't attempt
                            ! to spawn.
                            if (.not. (sys%nel == 0 .or. sys%nel == sys%lattice%nsites)) then
                                nattempts_current_det = decide_nattempts(rng, real_population(ireplica))
                                do iparticle = 1, nattempts_current_det
                                    ! Spawn from the first end.
                                    spawning_end = 1
                                    ! Attempt to spawn.
                                    call spawner_ptr(rng, sys, qmc_spawn%cutoff, real_factor, cdet1, &
                                                     walker_population(ireplica,idet), gen_excit_ptr, nspawned, connection)
                                    ! Spawn if attempt was successful.
                                    if (nspawned /= 0_int_p) then
                                        call create_spawned_particle_dm_ptr(sys%basis, cdet1%f, cdet2%f, connection, nspawned, &
                                                                            spawning_end, ireplica, qmc_spawn)

                                        if (abs(nspawned) >= bloom_stats%nparticles_encoded) &
                                            call accumulate_bloom_stats(bloom_stats, nspawned)
                                    end if

                                    ! Now attempt to spawn from the second end.
                                    spawning_end = 2
                                    call spawner_ptr(rng, sys, qmc_spawn%cutoff, real_factor, cdet2, &
                                                     walker_population(ireplica,idet), gen_excit_ptr, nspawned, connection)
                                    if (nspawned /= 0_int_p) then
                                        call create_spawned_particle_dm_ptr(sys%basis, cdet2%f, cdet1%f, connection, nspawned, &
                                                                            spawning_end, ireplica, qmc_spawn)

                                        if (abs(nspawned) >= bloom_stats%nparticles_encoded) &
                                            call accumulate_bloom_stats(bloom_stats, nspawned)
                                    end if
                                end do
                            end if

                            ! Clone or die.
                            ! We have contributions to the clone/death step from
                            ! both ends of the current walker. We do both of
                            ! these at once by using walker_data(:,idet) which,
                            ! when running a DMQMC algorithm, stores the average
                            ! of the two diagonal elements corresponding to the
                            ! two indicies of the density matrix.
                            call death_ptr(rng, walker_data(ireplica,idet), shift(ireplica), &
                                           walker_population(ireplica,idet), nparticles(ireplica), ndeath)
                        end do
                    end do

                    ! Now we have finished looping over all determinants, set
                    ! the symmetry labels back to their default value, if
                    ! necessary.
                    if (all_sym_sectors) then
                        sys%nel = nel_temp
                        sys%nvirt = sys%lattice%nsites - sys%nel
                    end if

                    ! Perform the annihilation step where the spawned walker
                    ! list is merged with the main walker list, and walkers of
                    ! opposite sign on the same sites are annihilated.
                    call direct_annihilation(sys, rng, initiator_approximation, nspawn_events)

                    call end_mc_cycle(nspawn_events, ndeath, nattempts)

                    ! If doing importance sampling *and* varying the weights of
                    ! the trial function, call a routine to update these weights
                    ! and alter the number of psips on each excitation level
                    ! accordingly.
                    if (dmqmc_vary_weights .and. iteration <= finish_varying_weights) call update_sampling_weights(rng, sys%basis)

                end do

                ! If averaging the shift to use in future beta loops, add
                ! contirubtion from this report.
                if (average_shift_until > 0) shift_profile(ireport) = shift_profile(ireport) + shift(1)

                ! Sum all quantities being considered across all MPI processes.
                call communicate_dmqmc_estimates()

                call update_shift_dmqmc(tot_nparticles, tot_nparticles_old, ireport)

                ! Forcibly disable update_tau as need to average over multiple loops over beta
                ! and hence want to use the same timestep throughout.
                call end_report_loop(sys, ireport, .false., tot_nparticles_old, t1, soft_exit, .false., bloom_stats=bloom_stats)

                if (soft_exit) exit

            end do

            if (soft_exit) exit

            ! If have just finished last beta loop of accumulating the shift,
            ! then perform the averaging and set average_shift_until to -1.
            ! This tells the shift update algorithm to use the values for
            ! shift stored in shift_profile.
            if (beta_cycle == average_shift_until) then
                shift_profile = shift_profile/average_shift_until
                average_shift_until = -1
            end if

            ! Calculate and output all requested estimators based on the reduced
            ! density matrix. This is for ground-state RDMs only.
            if (calc_ground_rdm) call call_ground_rdm_procedures(beta_cycle)
            ! Calculate and output new weights based on the psip distirubtion in
            ! the previous loop.
            if (dmqmc_find_weights) call output_and_alter_weights(sys%max_number_excitations)

        end do

        if (parent) write (6,'()')
        call write_bloom_report(bloom_stats)
        call load_balancing_report(qmc_spawn%mpi_time)

        if (soft_exit) then
            mc_cycles_done = mc_cycles_done + ncycles*ireport
        else
            mc_cycles_done = mc_cycles_done + ncycles*nreport
        end if

        if (dump_restart_file) then
            call dump_restart_hdf5(restart_info_global, mc_cycles_done, tot_nparticles)
            if (parent) write (6,'()')
        end if

        call dealloc_det_info_t(cdet1, .false.)
        call dealloc_det_info_t(cdet2, .false.)

    end subroutine do_dmqmc

    subroutine init_dmqmc_beta_loop(rng, beta_cycle)

        ! Initialise/reset DMQMC data for a new run over the temperature range.

        ! In/Out:
        !    rng: random number generator.
        ! In:
        !    beta_cycle: The index of the beta loop about to be started.

        use calc, only: seed
        use dSFMT_interface, only: dSFMT_t, dSFMT_init
        use parallel
        use utils, only: int_fmt

        type(dSFMT_t) :: rng
        integer, intent(in) :: beta_cycle
        integer :: new_seed

        ! Reset the current position in the spawning array to be the slot
        ! preceding the first slot.
        qmc_spawn%head = qmc_spawn%head_start

        ! Set all quantities back to their starting values.
        tot_walkers = 0
        shift = initial_shift
        nparticles = 0.0_dp
        if (allocated(reduced_density_matrix)) reduced_density_matrix = 0.0_p
        if (dmqmc_vary_weights) dmqmc_accumulated_probs = 1.0_p
        if (dmqmc_find_weights) excit_distribution = 0.0_p

        new_seed = seed+iproc+(beta_cycle-1)*nprocs

        if (beta_cycle /= 1 .and. parent) then
            write (6,'(a32,'//int_fmt(beta_cycle,1)//')') " # Resetting beta... Beta loop =", beta_cycle
            write (6,'(a52,'//int_fmt(new_seed,1)//',a1)') " # Resetting random number generator with a seed of:", new_seed, "."
        end if

        ! Reset the random number generator with new_seed = old_seed +
        ! nprocs (each beta loop)
        call dSFMT_init(new_seed, 50000, rng)

    end subroutine init_dmqmc_beta_loop

end module dmqmc
