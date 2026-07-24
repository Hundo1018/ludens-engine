; ModuleID = 'bindings/c/physics.c'
source_filename = "bindings/c/physics.c"
target datalayout = "e-m:e-p:32:32-p10:8:8-p20:8:8-i64:64-n32:64-S128-ni:1:10:20"
target triple = "wasm32"

@llvm.used = appending global [2 x ptr] [ptr @physics_sum_dense, ptr @physics_sum_keys], section "llvm.metadata"

; Function Attrs: nounwind
define hidden i32 @physics_sum_keys(ptr noundef %0) #0 {
  %2 = tail call i32 @ss_len(ptr noundef %0) #3
  %3 = icmp sgt i32 %2, 0
  br i1 %3, label %6, label %4

4:                                                ; preds = %6, %1
  %5 = phi i32 [ 0, %1 ], [ %10, %6 ]
  ret i32 %5

6:                                                ; preds = %1, %6
  %7 = phi i32 [ %11, %6 ], [ 0, %1 ]
  %8 = phi i32 [ %10, %6 ], [ 0, %1 ]
  %9 = tail call i32 @ss_dense_at(ptr noundef %0, i32 noundef %7) #3
  %10 = add nsw i32 %9, %8
  %11 = add nuw nsw i32 %7, 1
  %12 = icmp eq i32 %11, %2
  br i1 %12, label %4, label %6, !llvm.loop !2
}

declare i32 @ss_len(ptr noundef) local_unnamed_addr #1

declare i32 @ss_dense_at(ptr noundef, i32 noundef) local_unnamed_addr #1

; Function Attrs: nofree norecurse nosync nounwind memory(argmem: read)
define hidden i32 @physics_sum_dense(ptr nocapture noundef readonly %0, i32 noundef %1) #2 {
  %3 = icmp sgt i32 %1, 0
  br i1 %3, label %4, label %24

4:                                                ; preds = %2
  %5 = and i32 %1, 3
  %6 = icmp ult i32 %1, 4
  br i1 %6, label %9, label %7

7:                                                ; preds = %4
  %8 = and i32 %1, 2147483644
  br label %26

9:                                                ; preds = %26, %4
  %10 = phi i32 [ undef, %4 ], [ %44, %26 ]
  %11 = phi i32 [ 0, %4 ], [ %45, %26 ]
  %12 = phi i32 [ 0, %4 ], [ %44, %26 ]
  %13 = icmp eq i32 %5, 0
  br i1 %13, label %24, label %14

14:                                               ; preds = %9, %14
  %15 = phi i32 [ %21, %14 ], [ %11, %9 ]
  %16 = phi i32 [ %20, %14 ], [ %12, %9 ]
  %17 = phi i32 [ %22, %14 ], [ 0, %9 ]
  %18 = getelementptr inbounds i32, ptr %0, i32 %15
  %19 = load i32, ptr %18, align 4, !tbaa !4
  %20 = add nsw i32 %19, %16
  %21 = add nuw nsw i32 %15, 1
  %22 = add i32 %17, 1
  %23 = icmp eq i32 %22, %5
  br i1 %23, label %24, label %14, !llvm.loop !8

24:                                               ; preds = %9, %14, %2
  %25 = phi i32 [ 0, %2 ], [ %10, %9 ], [ %20, %14 ]
  ret i32 %25

26:                                               ; preds = %26, %7
  %27 = phi i32 [ 0, %7 ], [ %45, %26 ]
  %28 = phi i32 [ 0, %7 ], [ %44, %26 ]
  %29 = phi i32 [ 0, %7 ], [ %46, %26 ]
  %30 = getelementptr inbounds i32, ptr %0, i32 %27
  %31 = load i32, ptr %30, align 4, !tbaa !4
  %32 = add nsw i32 %31, %28
  %33 = or disjoint i32 %27, 1
  %34 = getelementptr inbounds i32, ptr %0, i32 %33
  %35 = load i32, ptr %34, align 4, !tbaa !4
  %36 = add nsw i32 %35, %32
  %37 = or disjoint i32 %27, 2
  %38 = getelementptr inbounds i32, ptr %0, i32 %37
  %39 = load i32, ptr %38, align 4, !tbaa !4
  %40 = add nsw i32 %39, %36
  %41 = or disjoint i32 %27, 3
  %42 = getelementptr inbounds i32, ptr %0, i32 %41
  %43 = load i32, ptr %42, align 4, !tbaa !4
  %44 = add nsw i32 %43, %40
  %45 = add nuw nsw i32 %27, 4
  %46 = add i32 %29, 4
  %47 = icmp eq i32 %46, %8
  br i1 %47, label %9, label %26, !llvm.loop !10
}

attributes #0 = { nounwind "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" "wasm-export-name"="physics_sum_keys" }
attributes #1 = { "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" }
attributes #2 = { nofree norecurse nosync nounwind memory(argmem: read) "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="generic" "target-features"="+mutable-globals,+sign-ext" "wasm-export-name"="physics_sum_dense" }
attributes #3 = { nobuiltin nounwind "no-builtins" }

!llvm.module.flags = !{!0}
!llvm.ident = !{!1}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{!"Ubuntu clang version 18.1.3 (1ubuntu1)"}
!2 = distinct !{!2, !3}
!3 = !{!"llvm.loop.mustprogress"}
!4 = !{!5, !5, i64 0}
!5 = !{!"int", !6, i64 0}
!6 = !{!"omnipotent char", !7, i64 0}
!7 = !{!"Simple C/C++ TBAA"}
!8 = distinct !{!8, !9}
!9 = !{!"llvm.loop.unroll.disable"}
!10 = distinct !{!10, !3}
