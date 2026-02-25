!mod$ v1 sum:5638b45afbda0a9f
module logic
integer(4),parameter::rank=3_4
integer(4),parameter::rank2=9_4
integer(4),parameter::total=45_4
integer(4)::two_in_a_bed(1_8:2_8)
integer(4)::three_in_a_bed
integer(4)::clear_out
integer(4)::four
integer(4)::to_do
integer(4)::fiendish
integer(4)::naked3
logical(4),parameter::new=.false._4
contains
subroutine new_solver(part,block,complete,key,changed)
integer(4)::part(:,:)
integer(4)::block(:,:,:)
logical(4)::complete
integer(4)::key
logical(4)::changed
end
end
