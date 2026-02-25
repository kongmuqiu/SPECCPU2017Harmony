!mod$ v1 sum:2c10a45a4db1217c
!need$ 5638b45afbda0a9f n logic
module brute_force
use logic,only:rank
use logic,only:rank2
use logic,only:total
use logic,only:two_in_a_bed
use logic,only:three_in_a_bed
use logic,only:clear_out
use logic,only:four
use logic,only:to_do
use logic,only:fiendish
use logic,only:naked3
use logic,only:new
use logic,only:new_solver
private::rank
private::rank2
private::total
private::two_in_a_bed
private::three_in_a_bed
private::clear_out
private::four
private::to_do
private::fiendish
private::naked3
private::new
private::new_solver
integer(4),parameter,private::r=9_4
integer(4),private::sudoku1(1_8:9_8,1_8:9_8)
integer(4),private::i
integer(4),private::j
integer(4),private::sudoku2(1_8:9_8,1_8:9_8)
integer(4),private::sudoku3(1_8:9_8,1_8:9_8)
integer(4)::soln
integer(4),private::block(1_8:9_8,1_8:9_8,1_8:9_8)
integer(4),private::val
integer(4),private::bc
integer(4),private::br
logical(4)::pearl
logical(4),private::changed
private::rearrange
private::digits_2
private::reflected
contains
subroutine brute(sudoku,key)
integer(4),intent(inout)::sudoku(1_8:9_8,1_8:9_8)
integer(4)::key
end
subroutine rearrange(sudoku,key)
integer(4),intent(inout)::sudoku(1_8:9_8,1_8:9_8)
integer(4),intent(in)::key
end
recursive subroutine digits_2(row)
integer(4),intent(in)::row
end
function covered(sudoku,pattern)
integer(4),intent(in)::sudoku(:,:)
integer(4),intent(in)::pattern(:,:)
logical(4)::covered
end
function reflected(ss,pp)
integer(4),intent(in)::ss(:,:)
integer(4),intent(inout)::pp(:,:)
logical(4)::reflected
end
end
