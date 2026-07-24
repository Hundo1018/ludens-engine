; ModuleID = 'toolchain/standin/sparse_set.c'
source_filename = "toolchain/standin/sparse_set.c"
target datalayout = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-n32:64-S128-ni:1:10:20"
target triple = "wasm32"

%struct.SparseSet = type { i32, i32, ptr, ptr }

@g_bump = internal unnamed_addr global i32 0, align 4
@__heap_base = external global i8, align 1
@llvm.used = appending global [7 x ptr] [ptr @ss_add, ptr @ss_contains, ptr @ss_create, ptr @ss_dense_at, ptr @ss_dense_ptr, ptr @ss_len, ptr @ss_remove], section "llvm.metadata"

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, argmem: write, inaccessiblemem: none)
define hidden noundef ptr @ss_create(i32 noundef %0) #0 {
  %2 = load i32, ptr @g_bump, align 4, !tbaa !2
  %3 = icmp eq i32 %2, 0
  %4 = add i32 %2, 7
  %5 = select i1 %3, i32 add (i32 ptrtoint (ptr @__heap_base to i32), i32 7), i32 %4
  %6 = and i32 %5, -8
  %7 = inttoptr i32 %6 to ptr
  store i32 %0, ptr %7, align 8, !tbaa !6
  %8 = getelementptr inbounds %struct.SparseSet, ptr %7, i32 0, i32 1
  store i32 0, ptr %8, align 4, !tbaa !10
  %9 = shl i32 %0, 2
  %10 = icmp eq i32 %6, -16
  %11 = add i32 %6, 23
  %12 = select i1 %10, i32 add (i32 ptrtoint (ptr @__heap_base to i32), i32 7), i32 %11
  %13 = and i32 %12, -8
  %14 = inttoptr i32 %13 to ptr
  %15 = add i32 %13, %9
  %16 = getelementptr inbounds %struct.SparseSet, ptr %7, i32 0, i32 2
  store ptr %14, ptr %16, align 8, !tbaa !11
  %17 = icmp eq i32 %15, 0
  %18 = add i32 %15, 7
  %19 = select i1 %17, i32 add (i32 ptrtoint (ptr @__heap_base to i32), i32 7), i32 %18
  %20 = and i32 %19, -8
  %21 = inttoptr i32 %20 to ptr
  %22 = add i32 %20, %9
  store i32 %22, ptr @g_bump, align 4, !tbaa !2
  %23 = getelementptr inbounds %struct.SparseSet, ptr %7, i32 0, i32 3
  store ptr %21, ptr %23, align 4, !tbaa !12
  %24 = icmp sgt i32 %0, 0
  br i1 %24, label %25, label %40

25:                                               ; preds = %1
  %26 = and i32 %0, 7
  %27 = icmp ult i32 %0, 8
  br i1 %27, label %30, label %28

28:                                               ; preds = %25
  %29 = and i32 %0, 2147483640
  br label %41

30:                                               ; preds = %41, %25
  %31 = phi i32 [ 0, %25 ], [ %59, %41 ]
  %32 = icmp eq i32 %26, 0
  br i1 %32, label %40, label %33

33:                                               ; preds = %30, %33
  %34 = phi i32 [ %37, %33 ], [ %31, %30 ]
  %35 = phi i32 [ %38, %33 ], [ 0, %30 ]
  %36 = getelementptr inbounds i32, ptr %14, i32 %34
  store i32 -1, ptr %36, align 4, !tbaa !13
  %37 = add nuw nsw i32 %34, 1
  %38 = add i32 %35, 1
  %39 = icmp eq i32 %38, %26
  br i1 %39, label %40, label %33, !llvm.loop !14

40:                                               ; preds = %30, %33, %1
  ret ptr %7

41:                                               ; preds = %41, %28
  %42 = phi i32 [ 0, %28 ], [ %59, %41 ]
  %43 = phi i32 [ 0, %28 ], [ %60, %41 ]
  %44 = getelementptr inbounds i32, ptr %14, i32 %42
  store i32 -1, ptr %44, align 8, !tbaa !13
  %45 = or disjoint i32 %42, 1
  %46 = getelementptr inbounds i32, ptr %14, i32 %45
  store i32 -1, ptr %46, align 4, !tbaa !13
  %47 = or disjoint i32 %42, 2
  %48 = getelementptr inbounds i32, ptr %14, i32 %47
  store i32 -1, ptr %48, align 8, !tbaa !13
  %49 = or disjoint i32 %42, 3
  %50 = getelementptr inbounds i32, ptr %14, i32 %49
  store i32 -1, ptr %50, align 4, !tbaa !13
  %51 = or disjoint i32 %42, 4
  %52 = getelementptr inbounds i32, ptr %14, i32 %51
  store i32 -1, ptr %52, align 8, !tbaa !13
  %53 = or disjoint i32 %42, 5
  %54 = getelementptr inbounds i32, ptr %14, i32 %53
  store i32 -1, ptr %54, align 4, !tbaa !13
  %55 = or disjoint i32 %42, 6
  %56 = getelementptr inbounds i32, ptr %14, i32 %55
  store i32 -1, ptr %56, align 8, !tbaa !13
  %57 = or disjoint i32 %42, 7
  %58 = getelementptr inbounds i32, ptr %14, i32 %57
  store i32 -1, ptr %58, align 4, !tbaa !13
  %59 = add nuw nsw i32 %42, 8
  %60 = add i32 %43, 8
  %61 = icmp eq i32 %60, %29
  br i1 %61, label %30, label %41, !llvm.loop !16
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(read, inaccessiblemem: none)
define hidden i32 @ss_contains(ptr nocapture noundef readonly %0, i32 noundef %1) #1 {
  %3 = icmp slt i32 %1, 0
  br i1 %3, label %24, label %4

4:                                                ; preds = %2
  %5 = load i32, ptr %0, align 4, !tbaa !6
  %6 = icmp sgt i32 %5, %1
  br i1 %6, label %7, label %24

7:                                                ; preds = %4
  %8 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 2
  %9 = load ptr, ptr %8, align 4, !tbaa !11
  %10 = getelementptr inbounds i32, ptr %9, i32 %1
  %11 = load i32, ptr %10, align 4, !tbaa !13
  %12 = icmp sgt i32 %11, -1
  br i1 %12, label %13, label %24

13:                                               ; preds = %7
  %14 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 1
  %15 = load i32, ptr %14, align 4, !tbaa !10
  %16 = icmp slt i32 %11, %15
  br i1 %16, label %17, label %24

17:                                               ; preds = %13
  %18 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 3
  %19 = load ptr, ptr %18, align 4, !tbaa !12
  %20 = getelementptr inbounds i32, ptr %19, i32 %11
  %21 = load i32, ptr %20, align 4, !tbaa !13
  %22 = icmp eq i32 %21, %1
  %23 = zext i1 %22 to i32
  br label %24

24:                                               ; preds = %7, %13, %17, %2, %4
  %25 = phi i32 [ 0, %4 ], [ 0, %2 ], [ 0, %13 ], [ 0, %7 ], [ %23, %17 ]
  ret i32 %25
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none)
define hidden void @ss_add(ptr nocapture noundef %0, i32 noundef %1) #2 {
  %3 = icmp slt i32 %1, 0
  br i1 %3, label %31, label %4

4:                                                ; preds = %2
  %5 = load i32, ptr %0, align 4, !tbaa !6
  %6 = icmp sgt i32 %5, %1
  br i1 %6, label %7, label %31

7:                                                ; preds = %4
  %8 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 2
  %9 = load ptr, ptr %8, align 4, !tbaa !11
  %10 = getelementptr inbounds i32, ptr %9, i32 %1
  %11 = load i32, ptr %10, align 4, !tbaa !13
  %12 = icmp sgt i32 %11, -1
  %13 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 1
  %14 = load i32, ptr %13, align 4, !tbaa !10
  %15 = icmp slt i32 %11, %14
  %16 = select i1 %12, i1 %15, i1 false
  br i1 %16, label %17, label %23

17:                                               ; preds = %7
  %18 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 3
  %19 = load ptr, ptr %18, align 4, !tbaa !12
  %20 = getelementptr inbounds i32, ptr %19, i32 %11
  %21 = load i32, ptr %20, align 4, !tbaa !13
  %22 = icmp eq i32 %21, %1
  br i1 %22, label %31, label %23

23:                                               ; preds = %7, %17
  %24 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 1
  store i32 %14, ptr %10, align 4, !tbaa !13
  %25 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 3
  %26 = load ptr, ptr %25, align 4, !tbaa !12
  %27 = load i32, ptr %24, align 4, !tbaa !10
  %28 = getelementptr inbounds i32, ptr %26, i32 %27
  store i32 %1, ptr %28, align 4, !tbaa !13
  %29 = load i32, ptr %24, align 4, !tbaa !10
  %30 = add nsw i32 %29, 1
  store i32 %30, ptr %24, align 4, !tbaa !10
  br label %31

31:                                               ; preds = %17, %2, %4, %23
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none)
define hidden void @ss_remove(ptr nocapture noundef %0, i32 noundef %1) #3 {
  %3 = icmp slt i32 %1, 0
  br i1 %3, label %30, label %4

4:                                                ; preds = %2
  %5 = load i32, ptr %0, align 4, !tbaa !6
  %6 = icmp sgt i32 %5, %1
  br i1 %6, label %7, label %30

7:                                                ; preds = %4
  %8 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 2
  %9 = load ptr, ptr %8, align 4, !tbaa !11
  %10 = getelementptr inbounds i32, ptr %9, i32 %1
  %11 = load i32, ptr %10, align 4, !tbaa !13
  %12 = icmp sgt i32 %11, -1
  br i1 %12, label %13, label %30

13:                                               ; preds = %7
  %14 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 1
  %15 = load i32, ptr %14, align 4, !tbaa !10
  %16 = icmp slt i32 %11, %15
  br i1 %16, label %17, label %30

17:                                               ; preds = %13
  %18 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 3
  %19 = load ptr, ptr %18, align 4, !tbaa !12
  %20 = getelementptr inbounds i32, ptr %19, i32 %11
  %21 = load i32, ptr %20, align 4, !tbaa !13
  %22 = icmp eq i32 %21, %1
  br i1 %22, label %23, label %30

23:                                               ; preds = %17
  %24 = getelementptr i32, ptr %19, i32 %15
  %25 = getelementptr i32, ptr %24, i32 -1
  %26 = load i32, ptr %25, align 4, !tbaa !13
  store i32 %26, ptr %20, align 4, !tbaa !13
  %27 = getelementptr inbounds i32, ptr %9, i32 %26
  store i32 %11, ptr %27, align 4, !tbaa !13
  %28 = load i32, ptr %14, align 4, !tbaa !10
  %29 = add nsw i32 %28, -1
  store i32 %29, ptr %14, align 4, !tbaa !10
  store i32 -1, ptr %10, align 4, !tbaa !13
  br label %30

30:                                               ; preds = %7, %13, %2, %4, %17, %23
  ret void
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read)
define hidden i32 @ss_len(ptr nocapture noundef readonly %0) #4 {
  %2 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 1
  %3 = load i32, ptr %2, align 4, !tbaa !10
  ret i32 %3
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(read, inaccessiblemem: none)
define hidden i32 @ss_dense_at(ptr nocapture noundef readonly %0, i32 noundef %1) #5 {
  %3 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 3
  %4 = load ptr, ptr %3, align 4, !tbaa !12
  %5 = getelementptr inbounds i32, ptr %4, i32 %1
  %6 = load i32, ptr %5, align 4, !tbaa !13
  ret i32 %6
}

; Function Attrs: mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read)
define hidden ptr @ss_dense_ptr(ptr nocapture noundef readonly %0) #6 {
  %2 = getelementptr inbounds %struct.SparseSet, ptr %0, i32 0, i32 3
  %3 = load ptr, ptr %2, align 4, !tbaa !12
  ret ptr %3
}

attributes #0 = { nofree norecurse nosync nounwind memory(readwrite, argmem: write, inaccessiblemem: none) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" "wasm-export-name"="ss_create" }
attributes #1 = { mustprogress nofree norecurse nosync nounwind willreturn memory(read, inaccessiblemem: none) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" "wasm-export-name"="ss_contains" }
attributes #2 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" "wasm-export-name"="ss_add" }
attributes #3 = { mustprogress nofree norecurse nosync nounwind willreturn memory(readwrite, inaccessiblemem: none) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" "wasm-export-name"="ss_remove" }
attributes #4 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" "wasm-export-name"="ss_len" }
attributes #5 = { mustprogress nofree norecurse nosync nounwind willreturn memory(read, inaccessiblemem: none) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" "wasm-export-name"="ss_dense_at" }
attributes #6 = { mustprogress nofree norecurse nosync nounwind willreturn memory(argmem: read) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" "wasm-export-name"="ss_dense_ptr" }

!llvm.module.flags = !{!0}
!llvm.ident = !{!1}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{!"Ubuntu clang version 18.1.3 (1ubuntu1)"}
!2 = !{!3, !3, i64 0}
!3 = !{!"long", !4, i64 0}
!4 = !{!"omnipotent char", !5, i64 0}
!5 = !{!"Simple C/C++ TBAA"}
!6 = !{!7, !8, i64 0}
!7 = !{!"", !8, i64 0, !8, i64 4, !9, i64 8, !9, i64 12}
!8 = !{!"int", !4, i64 0}
!9 = !{!"any pointer", !4, i64 0}
!10 = !{!7, !8, i64 4}
!11 = !{!7, !9, i64 8}
!12 = !{!7, !9, i64 12}
!13 = !{!8, !8, i64 0}
!14 = distinct !{!14, !15}
!15 = !{!"llvm.loop.unroll.disable"}
!16 = distinct !{!16, !17}
!17 = !{!"llvm.loop.mustprogress"}
